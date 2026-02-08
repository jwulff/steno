package daemon

import (
	"fmt"
	"os"
	"testing"
	"time"
)

// TestLiveDaemonStartStop tests starting and stopping recording via the daemon.
// Uses a single connection for both commands and events, matching how the TUI works.
// Skipped if the daemon socket doesn't exist.
func TestLiveDaemonStartStop(t *testing.T) {
	sockPath := SocketPath()
	if _, err := os.Stat(sockPath); os.IsNotExist(err) {
		t.Skip("daemon not running")
	}

	// Single client for commands
	client, err := Connect(sockPath)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer client.Close()

	// Check status first
	resp, err := client.SendCommand(Command{Cmd: "status"})
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	fmt.Printf("Initial status: ok=%v recording=%v status=%q device=%q\n",
		resp.OK, resp.Recording, resp.Status, resp.Device)

	// Get devices
	resp, err = client.SendCommand(Command{Cmd: "devices"})
	if err != nil {
		t.Fatalf("devices: %v", err)
	}
	fmt.Printf("Devices: %v\n", resp.Devices)

	// Start recording
	resp, err = client.SendCommand(Command{Cmd: "start"})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if !resp.OK {
		t.Fatalf("start failed: %s", resp.Error)
	}
	fmt.Printf("Started: sessionId=%s recording=%v\n", resp.SessionID, resp.Recording)

	// Check status while recording
	resp, err = client.SendCommand(Command{Cmd: "status"})
	if err != nil {
		t.Fatalf("status during recording: %v", err)
	}
	if resp.Recording == nil || !*resp.Recording {
		t.Error("expected recording=true during recording")
	}
	fmt.Printf("During recording: recording=%v segments=%v\n", resp.Recording, resp.Segments)

	// Stop recording (immediately, no delay)
	resp, err = client.SendCommand(Command{Cmd: "stop"})
	if err != nil {
		t.Fatalf("stop: %v", err)
	}
	if !resp.OK {
		t.Fatalf("stop failed: %s", resp.Error)
	}
	fmt.Printf("Stopped: recording=%v\n", resp.Recording)

	// Verify stopped
	resp, err = client.SendCommand(Command{Cmd: "status"})
	if err != nil {
		t.Fatalf("status after stop: %v", err)
	}
	if resp.Recording != nil && *resp.Recording {
		t.Error("expected recording=false after stop")
	}
	fmt.Printf("After stop: recording=%v status=%q\n", resp.Recording, resp.Status)

	fmt.Println("\nAll daemon commands working correctly!")
}

// TestLiveDaemonEventStream tests subscribing to events and receiving them.
// Uses a separate connection for the event stream.
// Skipped if the daemon socket doesn't exist.
func TestLiveDaemonEventStream(t *testing.T) {
	sockPath := SocketPath()
	if _, err := os.Stat(sockPath); os.IsNotExist(err) {
		t.Skip("daemon not running")
	}

	// Command connection
	cmdClient, err := Connect(sockPath)
	if err != nil {
		t.Fatalf("connect cmd: %v", err)
	}
	defer cmdClient.Close()

	// Event connection
	evClient, err := Connect(sockPath)
	if err != nil {
		t.Fatalf("connect ev: %v", err)
	}
	defer evClient.Close()

	// Subscribe on event connection
	resp, err := evClient.SendCommand(Command{Cmd: "subscribe"})
	if err != nil {
		t.Fatalf("subscribe: %v", err)
	}
	if !resp.OK {
		t.Fatalf("subscribe failed: %s", resp.Error)
	}

	// Start recording via command connection
	resp, err = cmdClient.SendCommand(Command{Cmd: "start"})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if !resp.OK {
		t.Fatalf("start failed: %s", resp.Error)
	}
	fmt.Printf("Recording started: sessionId=%s\n", resp.SessionID)

	// Collect events for 3 seconds
	eventCounts := map[string]int{}
	done := make(chan struct{})
	go func() {
		defer close(done)
		deadline := time.After(3 * time.Second)
		for {
			select {
			case <-deadline:
				return
			default:
				ev, err := evClient.ReadEvent()
				if err != nil {
					fmt.Printf("Event read error: %v\n", err)
					return
				}
				eventCounts[ev.Event]++
				switch ev.Event {
				case "level":
					// Don't print every level event (too noisy)
				case "partial":
					fmt.Printf("  partial: %q\n", ev.Text)
				case "segment":
					fmt.Printf("  segment: %q (seq=%v)\n", ev.Text, ev.SequenceNumber)
				default:
					fmt.Printf("  %s event received\n", ev.Event)
				}
			}
		}
	}()

	<-done

	// Stop recording
	resp, err = cmdClient.SendCommand(Command{Cmd: "stop"})
	if err != nil {
		t.Fatalf("stop: %v", err)
	}
	fmt.Println("Recording stopped")

	// Report
	fmt.Println("\nEvent counts:")
	total := 0
	for evType, count := range eventCounts {
		fmt.Printf("  %s: %d\n", evType, count)
		total += count
	}
	fmt.Printf("Total: %d events\n", total)

	if total == 0 {
		t.Error("expected at least some events during 3s recording")
	}
}
