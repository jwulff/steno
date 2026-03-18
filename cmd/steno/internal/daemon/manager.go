package daemon

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Manager handles daemon lifecycle: finding the binary, checking if it's
// running, starting it, and waiting for the socket to become available.
type Manager struct {
	// BasePath is the Steno application support directory.
	// Defaults to ~/Library/Application Support/Steno.
	BasePath string
}

// NewManager creates a Manager with default paths.
func NewManager() *Manager {
	home, _ := os.UserHomeDir()
	return &Manager{
		BasePath: filepath.Join(home, "Library", "Application Support", "Steno"),
	}
}

// pidPath returns the path to the daemon PID file.
func (m *Manager) pidPath() string {
	return filepath.Join(m.BasePath, "steno.pid")
}

// socketPath returns the path to the daemon Unix socket.
func (m *Manager) socketPath() string {
	return filepath.Join(m.BasePath, "steno.sock")
}

// logPath returns the path to the daemon log file.
func (m *Manager) logPath() string {
	return filepath.Join(m.BasePath, "daemon.log")
}

// IsRunning checks if the daemon is running by reading the PID file
// and verifying the process exists. Returns (running, pid, error).
func (m *Manager) IsRunning() (bool, int, error) {
	data, err := os.ReadFile(m.pidPath())
	if err != nil {
		if os.IsNotExist(err) {
			return false, 0, nil
		}
		return false, 0, fmt.Errorf("read pid file: %w", err)
	}

	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return false, 0, nil // malformed PID file, treat as not running
	}

	// Check if process exists
	process, err := os.FindProcess(pid)
	if err != nil {
		return false, 0, nil
	}

	// On Unix, FindProcess always succeeds. Use kill(pid, 0) to test existence.
	err = process.Signal(syscall.Signal(0))
	if err != nil {
		// Process does not exist — stale PID file
		return false, pid, nil
	}

	return true, pid, nil
}

// CleanStale removes stale PID and socket files left behind by a crashed daemon.
func (m *Manager) CleanStale() error {
	os.Remove(m.pidPath())
	os.Remove(m.socketPath())
	return nil
}

// FindBinary locates the steno-daemon binary using a three-tier strategy:
// 1. Same directory as the running steno binary
// 2. $STENO_DAEMON_PATH environment variable
// 3. $PATH lookup
func FindBinary() (string, error) {
	// 1. Co-located with this binary
	exe, err := os.Executable()
	if err == nil {
		colocated := filepath.Join(filepath.Dir(exe), "steno-daemon")
		if _, err := os.Stat(colocated); err == nil {
			return colocated, nil
		}
	}

	// 2. Environment variable override
	if p := os.Getenv("STENO_DAEMON_PATH"); p != "" {
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
		return "", fmt.Errorf("STENO_DAEMON_PATH=%q: file not found", p)
	}

	// 3. PATH lookup
	path, err := exec.LookPath("steno-daemon")
	if err != nil {
		return "", fmt.Errorf("steno-daemon not found. Install with: make install")
	}
	return path, nil
}

// Start spawns the daemon as a detached process that outlives the caller.
// stdout/stderr are redirected to the daemon log file.
func (m *Manager) Start(binaryPath string) error {
	// Ensure base directory exists
	if err := os.MkdirAll(m.BasePath, 0700); err != nil {
		return fmt.Errorf("create base directory: %w", err)
	}

	logFile, err := os.OpenFile(m.logPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return fmt.Errorf("open log file: %w", err)
	}

	cmd := exec.Command(binaryPath, "run")
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid: true, // Detach from controlling terminal
	}

	if err := cmd.Start(); err != nil {
		logFile.Close()
		return fmt.Errorf("start daemon: %w", err)
	}

	// Release the process so it outlives us — don't call cmd.Wait()
	if cmd.Process != nil {
		cmd.Process.Release()
	}

	logFile.Close()
	return nil
}

// WaitForSocket polls until the daemon socket becomes available or the
// context is cancelled. Returns nil when the socket is ready.
func (m *Manager) WaitForSocket(ctx context.Context) error {
	sockPath := m.socketPath()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return m.startupError(ctx.Err())
		case <-ticker.C:
			// Try to connect to the socket
			conn, err := net.DialTimeout("unix", sockPath, 500*time.Millisecond)
			if err == nil {
				conn.Close()
				return nil
			}
		}
	}
}

// startupError reads the last few lines of the daemon log to provide
// context for why the daemon failed to start.
func (m *Manager) startupError(cause error) error {
	tail := m.readLogTail(5)
	if tail != "" {
		return fmt.Errorf("daemon did not start: %w\nDaemon log:\n%s", cause, tail)
	}
	return fmt.Errorf("daemon did not start: %w", cause)
}

// readLogTail returns the last n lines of the daemon log file.
func (m *Manager) readLogTail(n int) string {
	data, err := os.ReadFile(m.logPath())
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// EnsureRunning checks if the daemon is running and starts it if not.
// Returns nil when the daemon is ready to accept connections.
func (m *Manager) EnsureRunning(ctx context.Context) error {
	running, _, err := m.IsRunning()
	if err != nil {
		return err
	}

	if running {
		// Verify socket is actually connectable
		conn, err := net.DialTimeout("unix", m.socketPath(), time.Second)
		if err == nil {
			conn.Close()
			return nil
		}
		// PID exists but socket doesn't work — daemon may be starting or broken
	}

	if !running {
		// Clean up stale files from a previous crash
		m.CleanStale()

		binaryPath, err := FindBinary()
		if err != nil {
			return err
		}

		if err := m.Start(binaryPath); err != nil {
			return err
		}
	}

	// Wait for socket with a 30-second timeout
	waitCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	return m.WaitForSocket(waitCtx)
}
