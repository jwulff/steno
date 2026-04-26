package daemon

import (
	"context"
	"errors"
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

// ghostDetectionGracePeriod is how long after the PID file appears we still
// give a daemon the benefit of the doubt for a missing socket. Past this,
// a PID-alive-socket-dead daemon is treated as a ghost and respawned.
const ghostDetectionGracePeriod = 5 * time.Second

// ghostTerminationDeadline is how long we wait for SIGTERM to take effect
// before escalating to SIGKILL when reaping a ghost daemon.
const ghostTerminationDeadline = 3 * time.Second

// processIdentifyTimeout bounds how long we'll wait for the executable-path
// lookup (ps) before giving up and treating the PID as unidentifiable.
const processIdentifyTimeout = 2 * time.Second

// daemonExecutableBasename is the basename we expect for a real steno-daemon.
// We match by basename rather than full path because the binary may live in
// any of: ~/.local/bin, daemon/.build/{debug,release}, $STENO_DAEMON_PATH, or
// elsewhere via $PATH. Basename match is conservative enough to prevent
// killing the wrong process while still recognising every legitimate install.
const daemonExecutableBasename = "steno-daemon"

// processIdentifier returns the executable path for a given PID, or "" if the
// PID can't be resolved (i.e. the process no longer exists). Returns a
// non-nil error on lookup failure (timeout, command error, etc.). Injectable
// on Manager so tests can simulate ps results without spawning real daemons.
type processIdentifier func(ctx context.Context, pid int) (string, error)

// Manager handles daemon lifecycle: finding the binary, checking if it's
// running, starting it, and waiting for the socket to become available.
type Manager struct {
	// BasePath is the Steno application support directory.
	// Defaults to ~/Library/Application Support/Steno.
	BasePath string

	// processIdentifier resolves a PID's executable path so ghost recovery
	// can verify the PID actually belongs to a steno-daemon before sending
	// SIGTERM. nil means "use defaultProcessIdentifier" — this is what
	// production code gets via NewManager and what tests get when they
	// don't override it.
	processIdentifier processIdentifier
}

// NewManager creates a Manager with default paths.
func NewManager() *Manager {
	home, _ := os.UserHomeDir()
	return &Manager{
		BasePath:          filepath.Join(home, "Library", "Application Support", "Steno"),
		processIdentifier: defaultProcessIdentifier,
	}
}

// identifyProcess calls the configured processIdentifier or falls back to the
// default ps-based implementation when the field is unset (zero-value
// Manager{} as used in many tests).
func (m *Manager) identifyProcess(ctx context.Context, pid int) (string, error) {
	if m.processIdentifier != nil {
		return m.processIdentifier(ctx, pid)
	}
	return defaultProcessIdentifier(ctx, pid)
}

// defaultProcessIdentifier returns the executable path of pid by shelling out
// to `ps -p <pid> -o comm=`. On macOS this prints the full path of the
// process executable (no truncation, no command-line args). The trailing `=`
// suppresses the column header.
//
// Distinguishes three outcomes:
//   - ("/path/to/exe", nil): live process, identity known.
//   - ("", nil):              PID does not exist (ps exited 1 with no stdout).
//   - ("", err):              lookup itself failed (timeout, ps missing, etc.).
func defaultProcessIdentifier(ctx context.Context, pid int) (string, error) {
	cmd := exec.CommandContext(ctx, "ps", "-p", strconv.Itoa(pid), "-o", "comm=")
	out, err := cmd.Output()
	if err != nil {
		// ps exits 1 when no process matches the PID. That's a definitive
		// "process gone" signal, not a lookup failure.
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 && len(strings.TrimSpace(string(out))) == 0 {
			return "", nil
		}
		// Context cancellation, ps missing, signal, etc. — surface as error
		// so the caller can take the conservative "do not kill" path.
		return "", fmt.Errorf("ps -p %d: %w", pid, err)
	}
	path := strings.TrimSpace(string(out))
	return path, nil
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
//
// When a PID file exists and points at a live process but the socket is
// unreachable past the grace period, the daemon is treated as a ghost,
// terminated, and respawned. See recoverGhostIfNeeded.
func (m *Manager) EnsureRunning(ctx context.Context) error {
	running, pid, err := m.IsRunning()
	if err != nil {
		return err
	}

	needSpawn := !running

	if running {
		// Verify socket is actually connectable.
		conn, err := net.DialTimeout("unix", m.socketPath(), time.Second)
		if err == nil {
			conn.Close()
			return nil
		}
		// PID exists but socket doesn't work — could be a daemon mid-startup
		// (still binding the socket) or a ghost (process alive, listener dead
		// or socket file deleted). recoverGhostIfNeeded uses PID-file age to
		// decide; if the daemon should have come up by now it kills and
		// cleans up so we can spawn a fresh one.
		recovered, rerr := m.recoverGhostIfNeeded(pid)
		if rerr != nil {
			return rerr
		}
		if recovered {
			needSpawn = true
		}
	}

	if needSpawn {
		// Clean up stale files from a previous crash (no-op if recoverGhostIfNeeded
		// already cleaned them).
		m.CleanStale()

		binaryPath, err := FindBinary()
		if err != nil {
			return err
		}

		if err := m.Start(binaryPath); err != nil {
			return err
		}
	}

	// Wait for socket with a 30-second timeout.
	waitCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	return m.WaitForSocket(waitCtx)
}

// recoverGhostIfNeeded inspects a daemon whose PID is alive but whose socket
// is unreachable. If the PID file is older than ghostDetectionGracePeriod,
// the process at that PID is examined more closely:
//
//   - If its executable basename is "steno-daemon", it is treated as a real
//     ghost: SIGTERM, then SIGKILL after ghostTerminationDeadline, then the
//     stale PID/socket files are cleaned.
//   - If the executable is something else (e.g. macOS recycled the PID for
//     an unrelated user process while our daemon was dead), we MUST NOT kill
//     it. The PID file is treated as stale, files are cleaned, and the caller
//     spawns a fresh daemon.
//   - If the identity lookup itself fails (ps timeout/error, empty result),
//     we take the same conservative no-kill path. The trade-off is explicit:
//     a false-negative (failing to kill a real ghost) is acceptable because
//     the spawn step that follows will fail loudly when the new daemon can't
//     bind its socket; a false-positive (killing an unrelated process) is
//     not acceptable because there is no recovery from that.
//
// Returns (true, nil) when ghost recovery ran (kill or stale-clean+respawn);
// (false, nil) when the daemon is still inside its startup grace window.
func (m *Manager) recoverGhostIfNeeded(pid int) (bool, error) {
	info, err := os.Stat(m.pidPath())
	if err != nil {
		// No PID file means there's nothing to recover from this path —
		// the caller will fall through to the spawn branch.
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("stat pid file: %w", err)
	}

	age := time.Since(info.ModTime())
	if age < ghostDetectionGracePeriod {
		// Daemon may legitimately still be binding its socket. Caller will
		// fall through to WaitForSocket.
		return false, nil
	}

	// Verify the PID actually belongs to a steno-daemon before we send any
	// signals. PID reuse is the regression we're guarding against here.
	idCtx, cancel := context.WithTimeout(context.Background(), processIdentifyTimeout)
	defer cancel()
	exePath, idErr := m.identifyProcess(idCtx, pid)

	switch {
	case idErr != nil:
		// Conservative path: treat as stale, do NOT kill.
		fmt.Fprintf(os.Stderr,
			"ghost daemon recovery: PID %d identity lookup failed (%v) — treating PID file as stale, not killing\n",
			pid, idErr)
		if err := m.CleanStale(); err != nil {
			return false, err
		}
		return true, nil

	case exePath == "":
		// Process disappeared between kill(0) and ps, or ps reported nothing.
		// Either way, no reason to kill — fall through to clean+respawn.
		fmt.Fprintf(os.Stderr,
			"ghost daemon recovery: PID %d no longer resolvable — treating PID file as stale\n",
			pid)
		if err := m.CleanStale(); err != nil {
			return false, err
		}
		return true, nil

	case filepath.Base(exePath) != daemonExecutableBasename:
		// PID points at an unrelated process (PID reuse). Do NOT kill it.
		fmt.Fprintf(os.Stderr,
			"ghost daemon recovery: PID %d is %q, not %s — stale PID file (likely PID reuse), not killing\n",
			pid, exePath, daemonExecutableBasename)
		if err := m.CleanStale(); err != nil {
			return false, err
		}
		return true, nil
	}

	// Confirmed steno-daemon — proceed with the kill path.
	// Stderr — the TUI redirects stdout for the bubbletea render.
	fmt.Fprintf(os.Stderr,
		"ghost daemon detected (PID %d, exe %s, socket unreachable, PID file age %s) — killing and respawning\n",
		pid, exePath, age.Round(time.Millisecond))

	if err := m.killGhost(pid); err != nil {
		return false, err
	}
	if err := m.CleanStale(); err != nil {
		return false, err
	}
	return true, nil
}

// killGhost sends SIGTERM to pid, polls for exit up to ghostTerminationDeadline,
// then escalates to SIGKILL if the process is still alive. Returns nil if the
// process is gone (or was already gone) by the time we return.
func (m *Manager) killGhost(pid int) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		// On Unix FindProcess never fails; defensively treat as already gone.
		return nil
	}

	// SIGTERM first. ESRCH means the process already exited — also fine.
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil && err != syscall.ESRCH {
		return fmt.Errorf("SIGTERM ghost daemon pid %d: %w", pid, err)
	}

	// Poll for the process to exit.
	deadline := time.Now().Add(ghostTerminationDeadline)
	for time.Now().Before(deadline) {
		if process.Signal(syscall.Signal(0)) != nil {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}

	// Still alive — escalate to SIGKILL.
	if err := syscall.Kill(pid, syscall.SIGKILL); err != nil && err != syscall.ESRCH {
		return fmt.Errorf("SIGKILL ghost daemon pid %d: %w", pid, err)
	}

	// Brief wait for the kernel to reap; bounded so tests don't hang.
	killDeadline := time.Now().Add(time.Second)
	for time.Now().Before(killDeadline) {
		if process.Signal(syscall.Signal(0)) != nil {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return nil
}
