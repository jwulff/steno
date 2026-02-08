// Package daemon provides the client and protocol types for communicating with
// steno-daemon over a Unix socket using NDJSON.
package daemon

// Command is sent from a client to the daemon.
type Command struct {
	Cmd         string   `json:"cmd"`
	Locale      string   `json:"locale,omitempty"`
	Device      string   `json:"device,omitempty"`
	SystemAudio *bool    `json:"systemAudio,omitempty"`
	Events      []string `json:"events,omitempty"`
}

// Response is returned by the daemon after processing a command.
type Response struct {
	OK          bool     `json:"ok"`
	SessionID   string   `json:"sessionId,omitempty"`
	Recording   *bool    `json:"recording,omitempty"`
	Segments    *int     `json:"segments,omitempty"`
	Devices     []string `json:"devices,omitempty"`
	Error       string   `json:"error,omitempty"`
	Status      string   `json:"status,omitempty"`
	Device      string   `json:"device,omitempty"`
	SystemAudio *bool    `json:"systemAudio,omitempty"`
}

// Event is streamed from the daemon to subscribed clients.
type Event struct {
	Event           string   `json:"event"`
	Text            string   `json:"text,omitempty"`
	Source          string   `json:"source,omitempty"`
	Mic             *float32 `json:"mic,omitempty"`
	Sys             *float32 `json:"sys,omitempty"`
	SessionID       string   `json:"sessionId,omitempty"`
	SequenceNumber  *int     `json:"sequenceNumber,omitempty"`
	Title           string   `json:"title,omitempty"`
	Message         string   `json:"message,omitempty"`
	Transient       *bool    `json:"transient,omitempty"`
	Recording       *bool    `json:"recording,omitempty"`
	ModelProcessing *bool    `json:"modelProcessing,omitempty"`
}

// BoolPtr returns a pointer to a bool value. Convenience for building commands.
func BoolPtr(b bool) *bool { return &b }
