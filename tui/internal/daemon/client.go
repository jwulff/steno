package daemon

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
)

// SocketPath returns the default daemon socket path.
func SocketPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "Steno", "steno.sock")
}

// Client communicates with steno-daemon over a Unix socket.
type Client struct {
	conn    net.Conn
	scanner *bufio.Scanner
	mu      sync.Mutex
}

// Connect dials the daemon Unix socket.
func Connect(socketPath string) (*Client, error) {
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("connect to daemon: %w", err)
	}

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024) // 1MB buffer

	return &Client{conn: conn, scanner: scanner}, nil
}

// Close shuts down the connection.
func (c *Client) Close() error {
	if c.conn != nil {
		return c.conn.Close()
	}
	return nil
}

// SendCommand sends a command and reads one response line.
func (c *Client) SendCommand(cmd Command) (Response, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	data, err := json.Marshal(cmd)
	if err != nil {
		return Response{}, fmt.Errorf("marshal command: %w", err)
	}

	data = append(data, '\n')
	if _, err := c.conn.Write(data); err != nil {
		return Response{}, fmt.Errorf("write command: %w", err)
	}

	if !c.scanner.Scan() {
		if err := c.scanner.Err(); err != nil {
			return Response{}, fmt.Errorf("read response: %w", err)
		}
		return Response{}, fmt.Errorf("connection closed")
	}

	var resp Response
	if err := json.Unmarshal(c.scanner.Bytes(), &resp); err != nil {
		return Response{}, fmt.Errorf("unmarshal response: %w", err)
	}

	return resp, nil
}

// ReadEvent reads the next NDJSON event line. Blocks until data arrives.
// After calling Subscribe, use this in a loop to receive events.
func (c *Client) ReadEvent() (Event, error) {
	if !c.scanner.Scan() {
		if err := c.scanner.Err(); err != nil {
			return Event{}, fmt.Errorf("read event: %w", err)
		}
		return Event{}, fmt.Errorf("connection closed")
	}

	var ev Event
	if err := json.Unmarshal(c.scanner.Bytes(), &ev); err != nil {
		return Event{}, fmt.Errorf("unmarshal event: %w", err)
	}

	return ev, nil
}
