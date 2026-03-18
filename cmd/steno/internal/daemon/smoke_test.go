package daemon

import (
	"fmt"
	"os"
	"testing"
)

// TestLiveDaemonConnection connects to a running daemon and tests basic commands.
// Skipped if the daemon socket doesn't exist.
func TestLiveDaemonConnection(t *testing.T) {
	sockPath := SocketPath()
	if _, err := os.Stat(sockPath); os.IsNotExist(err) {
		t.Skip("daemon not running (no socket at", sockPath, ")")
	}

	client, err := Connect(sockPath)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer client.Close()
	fmt.Println("Connected to daemon")

	// Test status command
	resp, err := client.SendCommand(Command{Cmd: "status"})
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if !resp.OK {
		t.Fatalf("status not ok: %s", resp.Error)
	}
	fmt.Printf("Status: ok=%v recording=%v device=%q status=%q\n",
		resp.OK, resp.Recording, resp.Device, resp.Status)

	// Test devices command
	resp, err = client.SendCommand(Command{Cmd: "devices"})
	if err != nil {
		t.Fatalf("devices: %v", err)
	}
	if !resp.OK {
		t.Fatalf("devices not ok: %s", resp.Error)
	}
	fmt.Printf("Devices: %v\n", resp.Devices)

	// Test subscribe (then immediately close — just verify it responds OK)
	client2, err := Connect(sockPath)
	if err != nil {
		t.Fatalf("connect for subscribe: %v", err)
	}
	defer client2.Close()

	resp, err = client2.SendCommand(Command{Cmd: "subscribe"})
	if err != nil {
		t.Fatalf("subscribe: %v", err)
	}
	if !resp.OK {
		t.Fatalf("subscribe not ok: %s", resp.Error)
	}
	fmt.Println("Subscribe: ok")
}
