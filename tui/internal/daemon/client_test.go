package daemon

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
)

// startMockDaemon creates a Unix socket that accepts one connection,
// reads a command, and writes back a canned response.
func startMockDaemon(t *testing.T, response Response) (string, func()) {
	t.Helper()

	dir := t.TempDir()
	sockPath := filepath.Join(dir, "test.sock")

	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()

		// Read one line (the command)
		buf := make([]byte, 4096)
		n, err := conn.Read(buf)
		if err != nil {
			return
		}
		_ = n // command received

		// Write response
		data, _ := json.Marshal(response)
		data = append(data, '\n')
		conn.Write(data)
	}()

	return sockPath, func() {
		ln.Close()
		os.Remove(sockPath)
	}
}

func TestClientSendCommand(t *testing.T) {
	recording := true
	resp := Response{
		OK:        true,
		SessionID: "sess-1",
		Recording: &recording,
	}

	sockPath, cleanup := startMockDaemon(t, resp)
	defer cleanup()

	client, err := Connect(sockPath)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer client.Close()

	got, err := client.SendCommand(Command{Cmd: "start"})
	if err != nil {
		t.Fatalf("send: %v", err)
	}

	if !got.OK {
		t.Error("ok = false, want true")
	}
	if got.SessionID != "sess-1" {
		t.Errorf("sessionId = %q, want %q", got.SessionID, "sess-1")
	}
}

func TestClientConnectFailure(t *testing.T) {
	_, err := Connect("/nonexistent/path/steno.sock")
	if err == nil {
		t.Error("expected error connecting to nonexistent socket")
	}
}

// startMockEventStream creates a daemon that sends a subscribe response
// then streams events.
func startMockEventStream(t *testing.T, events []Event) (string, func()) {
	t.Helper()

	dir := t.TempDir()
	sockPath := filepath.Join(dir, "test.sock")

	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()

		// Read subscribe command
		buf := make([]byte, 4096)
		conn.Read(buf)

		// Send subscribe response
		resp, _ := json.Marshal(Response{OK: true})
		conn.Write(append(resp, '\n'))

		// Stream events
		for _, ev := range events {
			data, _ := json.Marshal(ev)
			conn.Write(append(data, '\n'))
		}
	}()

	return sockPath, func() {
		ln.Close()
		os.Remove(sockPath)
	}
}

func TestClientReadEvents(t *testing.T) {
	mic := float32(0.5)
	events := []Event{
		{Event: "partial", Text: "hello"},
		{Event: "level", Mic: &mic},
	}

	sockPath, cleanup := startMockEventStream(t, events)
	defer cleanup()

	client, err := Connect(sockPath)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer client.Close()

	// Send subscribe
	_, err = client.SendCommand(Command{Cmd: "subscribe"})
	if err != nil {
		t.Fatalf("subscribe: %v", err)
	}

	// Read first event
	ev1, err := client.ReadEvent()
	if err != nil {
		t.Fatalf("read event 1: %v", err)
	}
	if ev1.Event != "partial" || ev1.Text != "hello" {
		t.Errorf("event1 = %+v", ev1)
	}

	// Read second event
	ev2, err := client.ReadEvent()
	if err != nil {
		t.Fatalf("read event 2: %v", err)
	}
	if ev2.Event != "level" || ev2.Mic == nil || *ev2.Mic != 0.5 {
		t.Errorf("event2 = %+v", ev2)
	}
}
