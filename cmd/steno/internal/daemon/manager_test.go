package daemon

import (
	"context"
	"errors"
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

// sleeper is a managed test subprocess. Wait() is called exactly once, in a
// goroutine started at spawn time, and the result is published on the
// `exited` channel. Tests use waitExited to block on reap and isAlive (via
// kill(pid, 0)) to assert the process is still running. t.Cleanup signals
// SIGKILL and drains the channel — it never calls Wait directly, which
// avoids the "Wait was already called" panic the previous helper risked
// when the in-test waiter goroutine raced with cleanup.
type sleeper struct {
	cmd    *exec.Cmd
	pid    int
	exited chan error // buffered (size 1); receives the Wait() result exactly once
}

// startSleeper spawns a `sleep 60` subprocess. Returns a sleeper handle.
// Wait() is owned by an internal goroutine; do not call cmd.Wait() yourself.
func startSleeper(t *testing.T) *sleeper {
	t.Helper()
	return startSubprocess(t, exec.Command("sleep", "60"))
}

// startSubprocess starts an arbitrary cmd as a managed sleeper. Useful for
// tests that need a SIGTERM-trapping shell instead of plain `sleep`.
func startSubprocess(t *testing.T, cmd *exec.Cmd) *sleeper {
	t.Helper()
	if err := cmd.Start(); err != nil {
		t.Fatalf("start subprocess: %v", err)
	}
	s := &sleeper{
		cmd:    cmd,
		pid:    cmd.Process.Pid,
		exited: make(chan error, 1),
	}
	go func() {
		_, err := cmd.Process.Wait()
		s.exited <- err
		close(s.exited)
	}()
	t.Cleanup(func() {
		// Best-effort SIGKILL to release the waiter; ignore errors. The
		// internal goroutine is the only Wait() caller, so we just drain.
		_ = syscall.Kill(s.pid, syscall.SIGKILL)
		select {
		case <-s.exited:
		case <-time.After(2 * time.Second):
			// Don't deadlock test cleanup if something is wedged.
		}
	})
	return s
}

// waitExited blocks until the subprocess is reaped, or until timeout.
// Returns true on successful reap.
func (s *sleeper) waitExited(timeout time.Duration) bool {
	select {
	case <-s.exited:
		return true
	case <-time.After(timeout):
		return false
	}
}

// isAlive returns true if kill(pid, 0) succeeds — i.e. the process exists
// and is signalable. Use this when you want to assert "still running" without
// racing the Wait goroutine.
func (s *sleeper) isAlive() bool {
	return syscall.Kill(s.pid, syscall.Signal(0)) == nil
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
	// Identity check confirms the PID is a steno-daemon — kill path should run.
	m.processIdentifier = stubIdentifier("/usr/local/bin/steno-daemon", nil)

	s := startSleeper(t)

	// Write the PID file and backdate its mtime past the grace period.
	pidPath := m.pidPath()
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(s.pid)), 0600); err != nil {
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

	recovered, err := m.recoverGhostIfNeeded(s.pid)
	if err != nil {
		t.Fatalf("recoverGhostIfNeeded: %v", err)
	}
	if !recovered {
		t.Fatal("expected recovered=true for old ghost PID")
	}

	// Sleeper should have been killed (and reaped). On macOS a zombie still
	// answers kill(0); reaping via Wait is the reliable signal.
	if !s.waitExited(2 * time.Second) {
		t.Errorf("expected sleeper PID %d to be dead after recovery", s.pid)
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
	// Grace-period gate runs before identity check, so the identifier
	// shouldn't even be consulted. Inject a panicking stub to assert that.
	m.processIdentifier = func(_ context.Context, _ int) (string, error) {
		t.Fatalf("processIdentifier should not be called inside grace period")
		return "", nil
	}

	s := startSleeper(t)

	// Fresh PID file — mtime is "now", well within the grace period.
	if err := os.WriteFile(m.pidPath(), []byte(strconv.Itoa(s.pid)), 0600); err != nil {
		t.Fatalf("write pid: %v", err)
	}

	recovered, err := m.recoverGhostIfNeeded(s.pid)
	if err != nil {
		t.Fatalf("recoverGhostIfNeeded: %v", err)
	}
	if recovered {
		t.Fatal("expected recovered=false for fresh PID file (still in startup grace)")
	}

	// Sleeper should still be alive — we did not kill it.
	if !s.isAlive() {
		t.Errorf("expected sleeper PID %d to still be alive", s.pid)
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
	m.processIdentifier = stubIdentifier("/usr/local/bin/steno-daemon", nil)

	// Spawn a shell that traps and ignores SIGTERM, then sleeps. SIGKILL
	// will still take it down. Give it a beat to install the trap before
	// recovery sends SIGTERM — without this, the shell can be hit before
	// it has parsed the script and the test reports a 50ms "fast kill"
	// instead of exercising the SIGTERM-then-SIGKILL escalation path.
	s := startSubprocess(t, exec.Command("/bin/sh", "-c", "trap '' TERM; sleep 60"))
	time.Sleep(150 * time.Millisecond)

	pidPath := m.pidPath()
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(s.pid)), 0600); err != nil {
		t.Fatalf("write pid: %v", err)
	}
	old := time.Now().Add(-30 * time.Second)
	if err := os.Chtimes(pidPath, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	start := time.Now()
	recovered, err := m.recoverGhostIfNeeded(s.pid)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("recoverGhostIfNeeded: %v", err)
	}
	if !recovered {
		t.Fatal("expected recovered=true after SIGKILL escalation")
	}

	// Process must be dead and reaped.
	if !s.waitExited(2 * time.Second) {
		t.Errorf("expected SIGTERM-ignoring process %d to be killed via SIGKILL", s.pid)
	}

	// We waited at least the SIGTERM deadline before escalating.
	if elapsed < ghostTerminationDeadline {
		t.Errorf("expected to wait >= %s before escalating, waited %s", ghostTerminationDeadline, elapsed)
	}
}

func TestRecoverGhostIfNeededBoundaryAge(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}
	m.processIdentifier = stubIdentifier("/usr/local/bin/steno-daemon", nil)

	s := startSleeper(t)

	pidPath := m.pidPath()
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(s.pid)), 0600); err != nil {
		t.Fatalf("write pid: %v", err)
	}
	// Backdate mtime to exactly the grace boundary. Comparison must be
	// `>=`, so this is a ghost. Add a small slack so monotonic-clock
	// rounding doesn't put us a hair under the threshold.
	boundary := time.Now().Add(-(ghostDetectionGracePeriod + 50*time.Millisecond))
	if err := os.Chtimes(pidPath, boundary, boundary); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	recovered, err := m.recoverGhostIfNeeded(s.pid)
	if err != nil {
		t.Fatalf("recoverGhostIfNeeded: %v", err)
	}
	if !recovered {
		t.Fatal("expected recovered=true at exactly the grace boundary (>= comparison)")
	}
	if !s.waitExited(2 * time.Second) {
		t.Errorf("expected sleeper PID %d to be dead", s.pid)
	}
}

// stubIdentifier returns a processIdentifier that always returns the given
// (path, err) pair. Use it to simulate ps results without spawning anything.
func stubIdentifier(path string, err error) processIdentifier {
	return func(_ context.Context, _ int) (string, error) {
		return path, err
	}
}

// TestRecoverGhostIfNeededUnrelatedProcess covers the PID-reuse safety case:
// the PID file points at a live process that is NOT steno-daemon (the kernel
// recycled the PID for an unrelated user process between the daemon's death
// and our auto-heal pass). The auto-heal must NOT kill it. Stale state is
// cleaned and the caller falls through to a fresh spawn.
func TestRecoverGhostIfNeededUnrelatedProcess(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}
	// Simulate the recycled PID belonging to /bin/sleep.
	m.processIdentifier = stubIdentifier("/bin/sleep", nil)

	s := startSleeper(t)

	pidPath := m.pidPath()
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(s.pid)), 0600); err != nil {
		t.Fatalf("write pid: %v", err)
	}
	old := time.Now().Add(-30 * time.Second)
	if err := os.Chtimes(pidPath, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
	if err := os.WriteFile(m.socketPath(), []byte(""), 0600); err != nil {
		t.Fatalf("write sentinel sock: %v", err)
	}

	recovered, err := m.recoverGhostIfNeeded(s.pid)
	if err != nil {
		t.Fatalf("recoverGhostIfNeeded: %v", err)
	}
	if !recovered {
		t.Fatal("expected recovered=true (treat as stale, clean files, respawn)")
	}

	// CRITICAL: the unrelated process MUST still be alive — we did not kill it.
	if !s.isAlive() {
		t.Fatalf("regression: unrelated process PID %d was killed by ghost recovery", s.pid)
	}

	// Stale files cleaned so the spawn path can write fresh ones.
	if _, err := os.Stat(m.pidPath()); !os.IsNotExist(err) {
		t.Errorf("expected PID file removed, stat err=%v", err)
	}
	if _, err := os.Stat(m.socketPath()); !os.IsNotExist(err) {
		t.Errorf("expected socket file removed, stat err=%v", err)
	}
}

// TestRecoverGhostIfNeededIdentifierError exercises the conservative
// fallback: if the identity lookup itself fails (timeout, ps error, etc.) we
// must NOT kill — false-positive (killing an unrelated process) is worse than
// false-negative (failing to reap a real ghost). Treat as stale.
func TestRecoverGhostIfNeededIdentifierError(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}
	m.processIdentifier = stubIdentifier("", errors.New("ps timed out"))

	s := startSleeper(t)

	pidPath := m.pidPath()
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(s.pid)), 0600); err != nil {
		t.Fatalf("write pid: %v", err)
	}
	old := time.Now().Add(-30 * time.Second)
	if err := os.Chtimes(pidPath, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	recovered, err := m.recoverGhostIfNeeded(s.pid)
	if err != nil {
		t.Fatalf("recoverGhostIfNeeded: %v", err)
	}
	if !recovered {
		t.Fatal("expected recovered=true on identifier error (conservative path)")
	}
	if !s.isAlive() {
		t.Fatalf("regression: process PID %d was killed despite identity-lookup error", s.pid)
	}
	if _, err := os.Stat(m.pidPath()); !os.IsNotExist(err) {
		t.Errorf("expected PID file removed, stat err=%v", err)
	}
}

// TestRecoverGhostIfNeededIdentifierEmpty handles the case where the
// identifier returns ("", nil) — typically meaning the PID disappeared
// between our kill(0) probe and the ps lookup. Same conservative behavior
// as the error path.
func TestRecoverGhostIfNeededIdentifierEmpty(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{BasePath: dir}
	m.processIdentifier = stubIdentifier("", nil)

	s := startSleeper(t)

	pidPath := m.pidPath()
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(s.pid)), 0600); err != nil {
		t.Fatalf("write pid: %v", err)
	}
	old := time.Now().Add(-30 * time.Second)
	if err := os.Chtimes(pidPath, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	recovered, err := m.recoverGhostIfNeeded(s.pid)
	if err != nil {
		t.Fatalf("recoverGhostIfNeeded: %v", err)
	}
	if !recovered {
		t.Fatal("expected recovered=true on empty identifier (conservative path)")
	}
	if !s.isAlive() {
		t.Fatalf("regression: process PID %d was killed despite empty identifier result", s.pid)
	}
}

// TestDefaultProcessIdentifierLive exercises the production ps-based
// implementation against a real subprocess. We don't make strong assumptions
// about the exact path ps reports — just that the basename ends in "sleep".
func TestDefaultProcessIdentifierLive(t *testing.T) {
	if _, err := exec.LookPath("ps"); err != nil {
		t.Skip("ps not available")
	}
	s := startSleeper(t)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	path, err := defaultProcessIdentifier(ctx, s.pid)
	if err != nil {
		t.Fatalf("defaultProcessIdentifier: %v", err)
	}
	if path == "" {
		t.Fatal("expected non-empty path for live PID")
	}
	if base := filepath.Base(path); base != "sleep" {
		t.Errorf("expected basename 'sleep', got %q (full=%q)", base, path)
	}
}

// TestDefaultProcessIdentifierMissing verifies that querying a PID that
// doesn't exist returns ("", nil) — the agreed signal that the process is
// gone, distinct from a lookup error.
func TestDefaultProcessIdentifierMissing(t *testing.T) {
	if _, err := exec.LookPath("ps"); err != nil {
		t.Skip("ps not available")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	// PID 999999999 is far above any reasonable system limit on macOS.
	path, err := defaultProcessIdentifier(ctx, 999999999)
	if err != nil {
		t.Fatalf("defaultProcessIdentifier on missing PID: unexpected err=%v", err)
	}
	if path != "" {
		t.Errorf("expected empty path for missing PID, got %q", path)
	}
}
