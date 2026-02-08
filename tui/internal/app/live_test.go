package app

import (
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jwulff/steno/tui/internal/daemon"

	tea "github.com/charmbracelet/bubbletea"
)

// TestLiveTUIFlow exercises the full TUI model lifecycle against a running daemon.
// Skipped if the daemon isn't running.
func TestLiveTUIFlow(t *testing.T) {
	sockPath := daemon.SocketPath()
	if _, err := os.Stat(sockPath); os.IsNotExist(err) {
		t.Skip("daemon not running")
	}

	m := New()

	// Simulate terminal size
	m, _ = applyUpdate(m, tea.WindowSizeMsg{Width: 120, Height: 40})
	view := m.View()
	if view == "Initializing..." {
		t.Error("view should render after WindowSizeMsg")
	}
	fmt.Println("=== Initial View ===")
	fmt.Println(view)

	// Connect to daemon
	client, err := daemon.Connect(sockPath)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	m, _ = applyUpdate(m, DaemonConnectedMsg{Client: client})
	if !m.connected {
		t.Fatal("expected connected")
	}
	fmt.Printf("Connected: status=%q\n", m.statusText)

	// Fetch status
	resp, err := client.SendCommand(daemon.Command{Cmd: "status"})
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	m, _ = applyUpdate(m, StatusResponseMsg{Response: resp})
	fmt.Printf("Status: recording=%v status=%q\n", m.recording, m.statusText)

	// Fetch devices
	resp, err = client.SendCommand(daemon.Command{Cmd: "devices"})
	if err != nil {
		t.Fatalf("devices: %v", err)
	}
	m, _ = applyUpdate(m, DevicesResponseMsg{Response: resp})
	fmt.Printf("Devices: %v\n", m.devices)

	// Render view in connected/idle state
	view = m.View()
	fmt.Println("\n=== Connected Idle View ===")
	fmt.Println(view)

	// Subscribe for events (use a second connection)
	evClient, err := daemon.Connect(sockPath)
	if err != nil {
		t.Fatalf("connect event: %v", err)
	}
	defer evClient.Close()

	subResp, err := evClient.SendCommand(daemon.Command{Cmd: "subscribe"})
	if err != nil {
		t.Fatalf("subscribe: %v", err)
	}
	if !subResp.OK {
		t.Fatalf("subscribe failed: %s", subResp.Error)
	}

	// Start recording via command connection
	resp, err = client.SendCommand(daemon.Command{Cmd: "start"})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	m, _ = applyUpdate(m, StartResponseMsg{Response: resp})
	fmt.Printf("\nStarted recording: sessionId=%s recording=%v\n", m.sessionID, m.recording)

	// Read events for 5 seconds
	fmt.Println("\n=== Collecting events for 5 seconds ===")
	eventCounts := map[string]int{}
	done := make(chan struct{})
	go func() {
		defer close(done)
		deadline := time.After(5 * time.Second)
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

				// Feed events into model
				switch ev.Event {
				case "partial":
					m.handleEvent(ev)
					fmt.Printf("  partial: %q\n", ev.Text)
				case "segment":
					m.handleEvent(ev)
					fmt.Printf("  segment: %q (seq=%v)\n", ev.Text, ev.SequenceNumber)
				case "level":
					m.handleEvent(ev)
				case "status":
					m.handleEvent(ev)
					fmt.Printf("  status: recording=%v\n", ev.Recording)
				case "error":
					m.handleEvent(ev)
					fmt.Printf("  error: %s\n", ev.Message)
				default:
					fmt.Printf("  %s event\n", ev.Event)
				}
			}
		}
	}()

	<-done

	// Render view during recording
	view = m.View()
	fmt.Println("\n=== Recording View ===")
	fmt.Println(view)

	// Stop recording
	resp, err = client.SendCommand(daemon.Command{Cmd: "stop"})
	if err != nil {
		t.Fatalf("stop: %v", err)
	}
	m, _ = applyUpdate(m, StopResponseMsg{Response: resp})
	fmt.Printf("\nStopped: recording=%v\n", m.recording)

	// Render final view
	view = m.View()
	fmt.Println("\n=== Final View ===")
	fmt.Println(view)

	// Event summary
	fmt.Println("\n=== Event Summary ===")
	total := 0
	for evType, count := range eventCounts {
		fmt.Printf("  %s: %d\n", evType, count)
		total += count
	}
	fmt.Printf("  Total: %d events\n", total)
	fmt.Printf("  Transcript entries: %d\n", len(m.entries))
	fmt.Printf("  Partial text: %q\n", m.partialText)

	if total == 0 {
		t.Error("expected at least some events during 5s recording")
	}

	// Clean up
	client.Close()
}

func applyUpdate(m Model, msg tea.Msg) (Model, tea.Cmd) {
	newModel, cmd := m.Update(msg)
	return newModel.(Model), cmd
}
