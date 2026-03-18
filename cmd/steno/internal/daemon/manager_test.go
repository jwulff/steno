package daemon

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
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
