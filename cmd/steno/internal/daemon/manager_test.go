package daemon

import (
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

func TestIsRunningNoPIDFile(t *testing.T) {
	m := &Manager{BasePath: t.TempDir()}

	running, pid, err := m.IsRunning()
	if err != nil {
		t.Fatalf("IsRunning: %v", err)
	}
	if running {
		t.Error("expected not running")
	}
	if pid != 0 {
		t.Errorf("expected pid 0, got %d", pid)
	}
}

func TestIsRunningStalePID(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}

	// Write a PID that definitely doesn't exist
	os.WriteFile(m.pidPath(), []byte("999999999"), 0600)

	running, pid, err := m.IsRunning()
	if err != nil {
		t.Fatalf("IsRunning: %v", err)
	}
	if running {
		t.Error("expected not running with stale PID")
	}
	if pid != 999999999 {
		t.Errorf("expected pid 999999999, got %d", pid)
	}
}

func TestIsRunningCurrentProcess(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}

	// Use our own PID — we know this process exists
	myPID := os.Getpid()
	os.WriteFile(m.pidPath(), []byte(strconv.Itoa(myPID)), 0600)

	running, pid, err := m.IsRunning()
	if err != nil {
		t.Fatalf("IsRunning: %v", err)
	}
	if !running {
		t.Error("expected running for current process")
	}
	if pid != myPID {
		t.Errorf("expected pid %d, got %d", myPID, pid)
	}
}

func TestIsRunningMalformedPID(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}

	os.WriteFile(m.pidPath(), []byte("not-a-number"), 0600)

	running, _, err := m.IsRunning()
	if err != nil {
		t.Fatalf("IsRunning: %v", err)
	}
	if running {
		t.Error("expected not running with malformed PID")
	}
}

func TestCleanStale(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}

	// Create stale files
	pidPath := m.pidPath()
	sockPath := m.socketPath()
	os.WriteFile(pidPath, []byte("12345"), 0600)
	os.WriteFile(sockPath, []byte(""), 0600)

	err := m.CleanStale()
	if err != nil {
		t.Fatalf("CleanStale: %v", err)
	}

	if _, err := os.Stat(pidPath); !os.IsNotExist(err) {
		t.Error("expected PID file to be removed")
	}
	if _, err := os.Stat(sockPath); !os.IsNotExist(err) {
		t.Error("expected socket file to be removed")
	}
}

func TestCleanStaleNoFiles(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}

	// Should not error when files don't exist
	err := m.CleanStale()
	if err != nil {
		t.Fatalf("CleanStale: %v", err)
	}
}

func TestFindBinaryEnvVar(t *testing.T) {
	// Create a fake binary
	dir := t.TempDir()
	fakeBin := filepath.Join(dir, "steno-daemon")
	os.WriteFile(fakeBin, []byte("#!/bin/sh"), 0755)

	t.Setenv("STENO_DAEMON_PATH", fakeBin)

	path, err := FindBinary()
	if err != nil {
		t.Fatalf("FindBinary: %v", err)
	}
	if path != fakeBin {
		t.Errorf("expected %q, got %q", fakeBin, path)
	}
}

func TestFindBinaryEnvVarMissing(t *testing.T) {
	t.Setenv("STENO_DAEMON_PATH", "/nonexistent/steno-daemon")

	_, err := FindBinary()
	if err == nil {
		t.Fatal("expected error for missing STENO_DAEMON_PATH")
	}
}

func TestReadLogTail(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}

	// Write log with multiple lines
	logContent := "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\n"
	os.WriteFile(m.logPath(), []byte(logContent), 0600)

	tail := m.readLogTail(3)
	if tail != "line 5\nline 6\nline 7" {
		t.Errorf("tail = %q, want last 3 lines", tail)
	}
}

func TestReadLogTailNoFile(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}

	tail := m.readLogTail(3)
	if tail != "" {
		t.Errorf("expected empty tail for missing log, got %q", tail)
	}
}

func TestReadLogTailShort(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}

	os.WriteFile(m.logPath(), []byte("only one line"), 0600)

	tail := m.readLogTail(5)
	if tail != "only one line" {
		t.Errorf("tail = %q, want %q", tail, "only one line")
	}
}

func TestPaths(t *testing.T) {
	m := &Manager{BasePath: "/test/path"}

	if m.pidPath() != "/test/path/steno.pid" {
		t.Errorf("pidPath = %q", m.pidPath())
	}
	if m.socketPath() != "/test/path/steno.sock" {
		t.Errorf("socketPath = %q", m.socketPath())
	}
	if m.logPath() != "/test/path/daemon.log" {
		t.Errorf("logPath = %q", m.logPath())
	}
}

// startSleeper spawns a `sleep 60` subprocess and registers cleanup that
// kills it (best-effort) when the test ends. Returns the PID.
func startSleeper(t *testing.T) (*exec.Cmd, int) {
	t.Helper()
	cmd := exec.Command("sleep", "60")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start sleeper: %v", err)
	}
	pid := cmd.Process.Pid
	t.Cleanup(func() {
		_ = syscall.Kill(pid, syscall.SIGKILL)
		_, _ = cmd.Process.Wait()
	})
	return cmd, pid
}

// waitExited blocks until the given subprocess is reaped, or until timeout.
// Returns true on successful reap. We wait via cmd.Process.Wait so we observe
// actual exit, not a zombie that still answers kill(0) on macOS.
func waitExited(cmd *exec.Cmd, timeout time.Duration) bool {
	done := make(chan struct{})
	go func() {
		_, _ = cmd.Process.Wait()
		close(done)
	}()
	select {
	case <-done:
		return true
	case <-time.After(timeout):
		return false
	}
}

func TestEnsureRunningHealthySocket(t *testing.T) {
	// Unix domain socket paths on macOS are capped around 104 chars.
	// t.TempDir() returns paths under /var/folders/... that blow the limit
	// once we append /steno.sock, so use a short /tmp path instead.
	dir, err := os.MkdirTemp("/tmp", "steno-ghost-")
	if err != nil {
		t.Fatalf("mkdir tmp: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	m := &Manager{BasePath: dir}

	// PID file points at the current process — guaranteed alive.
	if err := os.WriteFile(m.pidPath(), []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
		t.Fatalf("write pid: %v", err)
	}

	// Stand up a Unix socket listener at the expected path so DialTimeout
	// succeeds.
	ln, err := net.Listen("unix", m.socketPath())
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	// Accept-and-discard so dials don't block.
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := m.EnsureRunning(ctx); err != nil {
		t.Fatalf("EnsureRunning: %v", err)
	}
}

func TestRecoverGhostIfNeededKillsOldGhost(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}

	cmd, pid := startSleeper(t)

	// Write the PID file and backdate its mtime past the grace period.
	pidPath := m.pidPath()
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(pid)), 0600); err != nil {
		t.Fatalf("write pid: %v", err)
	}
	old := time.Now().Add(-30 * time.Second)
	if err := os.Chtimes(pidPath, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	// No socket file. Drop a sentinel socket file so we can verify cleanup
	// removes it.
	if err := os.WriteFile(m.socketPath(), []byte(""), 0600); err != nil {
		t.Fatalf("write sentinel sock: %v", err)
	}

	recovered, err := m.recoverGhostIfNeeded(pid)
	if err != nil {
		t.Fatalf("recoverGhostIfNeeded: %v", err)
	}
	if !recovered {
		t.Fatal("expected recovered=true for old ghost PID")
	}

	// Sleeper should have been killed (and reaped). On macOS a zombie still
	// answers kill(0); reaping via Wait is the reliable signal.
	if !waitExited(cmd, 2*time.Second) {
		t.Errorf("expected sleeper PID %d to be dead after recovery", pid)
	}

	// Stale files cleaned.
	if _, err := os.Stat(m.pidPath()); !os.IsNotExist(err) {
		t.Errorf("expected PID file removed, stat err=%v", err)
	}
	if _, err := os.Stat(m.socketPath()); !os.IsNotExist(err) {
		t.Errorf("expected socket file removed, stat err=%v", err)
	}
}

func TestRecoverGhostIfNeededFreshPIDFile(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}

	cmd, pid := startSleeper(t)

	// Fresh PID file — mtime is "now", well within the grace period.
	if err := os.WriteFile(m.pidPath(), []byte(strconv.Itoa(pid)), 0600); err != nil {
		t.Fatalf("write pid: %v", err)
	}

	recovered, err := m.recoverGhostIfNeeded(pid)
	if err != nil {
		t.Fatalf("recoverGhostIfNeeded: %v", err)
	}
	if recovered {
		t.Fatal("expected recovered=false for fresh PID file (still in startup grace)")
	}

	// Sleeper should still be alive — we did not kill it. If Wait returns
	// quickly the process exited (which would be a bug here).
	if waitExited(cmd, 200*time.Millisecond) {
		t.Errorf("expected sleeper PID %d to still be alive", pid)
	}
	// PID file should still be there too.
	if _, err := os.Stat(m.pidPath()); err != nil {
		t.Errorf("expected PID file still present, stat err=%v", err)
	}
}

func TestRecoverGhostIfNeededSIGKILLEscalation(t *testing.T) {
	if _, err := os.Stat("/bin/sh"); err != nil {
		t.Skip("/bin/sh unavailable")
	}

	dir := t.TempDir()
	m := &Manager{BasePath: dir}

	// Spawn a shell that traps and ignores SIGTERM, then sleeps. SIGKILL
	// will still take it down.
	cmd := exec.Command("/bin/sh", "-c", "trap '' TERM; sleep 60")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start trap shell: %v", err)
	}
	pid := cmd.Process.Pid
	t.Cleanup(func() {
		_ = syscall.Kill(pid, syscall.SIGKILL)
		_, _ = cmd.Process.Wait()
	})

	pidPath := m.pidPath()
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(pid)), 0600); err != nil {
		t.Fatalf("write pid: %v", err)
	}
	old := time.Now().Add(-30 * time.Second)
	if err := os.Chtimes(pidPath, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	start := time.Now()
	recovered, err := m.recoverGhostIfNeeded(pid)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("recoverGhostIfNeeded: %v", err)
	}
	if !recovered {
		t.Fatal("expected recovered=true after SIGKILL escalation")
	}

	// Process must be dead and reaped.
	if !waitExited(cmd, 2*time.Second) {
		t.Errorf("expected SIGTERM-ignoring process %d to be killed via SIGKILL", pid)
	}

	// We waited at least the SIGTERM deadline before escalating.
	if elapsed < ghostTerminationDeadline {
		t.Errorf("expected to wait >= %s before escalating, waited %s", ghostTerminationDeadline, elapsed)
	}
}

func TestRecoverGhostIfNeededBoundaryAge(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}

	cmd, pid := startSleeper(t)

	pidPath := m.pidPath()
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(pid)), 0600); err != nil {
		t.Fatalf("write pid: %v", err)
	}
	// Backdate mtime to exactly the grace boundary. Comparison must be
	// `>=`, so this is a ghost. Add a small slack so monotonic-clock
	// rounding doesn't put us a hair under the threshold.
	boundary := time.Now().Add(-(ghostDetectionGracePeriod + 50*time.Millisecond))
	if err := os.Chtimes(pidPath, boundary, boundary); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	recovered, err := m.recoverGhostIfNeeded(pid)
	if err != nil {
		t.Fatalf("recoverGhostIfNeeded: %v", err)
	}
	if !recovered {
		t.Fatal("expected recovered=true at exactly the grace boundary (>= comparison)")
	}
	if !waitExited(cmd, 2*time.Second) {
		t.Errorf("expected sleeper PID %d to be dead", pid)
	}
}
