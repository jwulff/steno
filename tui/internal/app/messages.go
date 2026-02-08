package app

import "github.com/jwulff/steno/tui/internal/daemon"

// DaemonConnectedMsg is sent when both daemon connections are established.
type DaemonConnectedMsg struct {
	Client   *daemon.Client // for commands (start, stop, status, devices)
	EvClient *daemon.Client // for event subscription
}

// DaemonConnectErrorMsg is sent when the daemon connection fails.
type DaemonConnectErrorMsg struct {
	Err error
}

// DaemonEventMsg wraps a streamed event from the daemon.
type DaemonEventMsg struct {
	Event daemon.Event
}

// DaemonEventErrorMsg is sent when the event stream encounters an error.
type DaemonEventErrorMsg struct {
	Err error
}

// StatusResponseMsg carries the response to a status command.
type StatusResponseMsg struct {
	Response daemon.Response
}

// DevicesResponseMsg carries the response to a devices command.
type DevicesResponseMsg struct {
	Response daemon.Response
}

// StartResponseMsg carries the response to a start command.
type StartResponseMsg struct {
	Response daemon.Response
}

// StopResponseMsg carries the response to a stop command.
type StopResponseMsg struct {
	Response daemon.Response
}

// PartialTextMsg updates partial transcription text.
type PartialTextMsg struct {
	Text   string
	Source string
}

// SegmentMsg represents a finalized transcript segment.
type SegmentMsg struct {
	Text           string
	Source         string
	SequenceNumber int
}

// AudioLevelMsg carries audio level data.
type AudioLevelMsg struct {
	Mic float32
	Sys float32
}

// StatusEventMsg carries a status change event.
type StatusEventMsg struct {
	Recording bool
}

// ErrorEventMsg carries an error event from the daemon.
type ErrorEventMsg struct {
	Message   string
	Transient bool
}

// ModelProcessingMsg indicates LLM processing state.
type ModelProcessingMsg struct {
	Processing bool
}

// TopicsEventMsg signals that topics have been updated.
type TopicsEventMsg struct {
	Title string
}

// ClearTransientErrorMsg clears a transient error after a timeout.
type ClearTransientErrorMsg struct{}

// TopicsLoadedMsg carries topics loaded from SQLite.
type TopicsLoadedMsg struct {
	Topics []TopicLoaded
}

// TopicLoaded carries a topic from the database.
type TopicLoaded struct {
	ID      string
	Title   string
	Summary string
}

// ReconnectTickMsg triggers a reconnection attempt.
type ReconnectTickMsg struct{}
