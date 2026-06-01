// Package daemon provides the client and protocol types for communicating with
// steno-daemon over a Unix socket using NDJSON.
package daemon

// Command is sent from a client to the daemon.
//
// Mirrors `daemon/Sources/StenoDaemon/Socket/DaemonProtocol.swift` —
// when adding fields here, add them on the Swift side too. Field names
// must match the JSON keys exactly.
type Command struct {
	Cmd         string   `json:"cmd"`
	Locale      string   `json:"locale,omitempty"`
	Device      string   `json:"device,omitempty"`
	SystemAudio *bool    `json:"systemAudio,omitempty"`
	Events      []string `json:"events,omitempty"`

	// AutoResumeSeconds is the wall-clock window (seconds from now)
	// after which a `pause` command auto-resumes. Nil + Indefinite=nil
	// falls back to the daemon-side default. Ignored for non-pause
	// commands. (U10)
	AutoResumeSeconds *float64 `json:"autoResumeSeconds,omitempty"`

	// Indefinite, when true, requests an indefinite pause with no
	// auto-resume timer. Mutually exclusive with AutoResumeSeconds.
	// (U10, privacy-critical)
	Indefinite *bool `json:"indefinite,omitempty"`
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

	// Paused is true when the engine is currently in `.paused` state.
	// Surfaced on `status` and `pause` / `resume` responses so a
	// connecting TUI sees the pause state immediately. (U10)
	Paused *bool `json:"paused,omitempty"`

	// PausedIndefinitely is true when the active pause has no
	// auto-resume timer. (U10, matches sessions.paused_indefinitely=1)
	PausedIndefinitely *bool `json:"pausedIndefinitely,omitempty"`

	// PauseExpiresAt is the Unix timestamp (seconds) at which the
	// auto-resume timer will fire. Nil for indefinite pauses or when
	// not paused. (U10)
	PauseExpiresAt *float64 `json:"pauseExpiresAt,omitempty"`
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
	StartedAt       *float64 `json:"startedAt,omitempty"`

	// Pause-state event payload. The daemon emits an `event:"pause_state"`
	// on every transition into and out of `.paused`. (U10)
	Paused             *bool    `json:"paused,omitempty"`
	PausedIndefinitely *bool    `json:"pausedIndefinitely,omitempty"`
	PauseExpiresAt     *float64 `json:"pauseExpiresAt,omitempty"`

	// #61 — diarization speaker assignment. Carried on `speaker_label` events
	// (and tolerated on any event that wants to include it). Empty for
	// un-diarized events.
	SpeakerID string `json:"speakerId,omitempty"`

	// #62 — model_status event payload. The daemon emits
	// `event:"model_status"` whenever an on-device model pipeline changes
	// readiness. `Component` is "transcription" (Layer A — the live
	// transcript itself) or "diarization" (Layer B — speaker labels).
	// `State` is "preparing", "ready", or "unavailable". `Reason` is
	// present ONLY when State == "unavailable".
	Component string `json:"component,omitempty"`
	State     string `json:"state,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

// BoolPtr returns a pointer to a bool value. Convenience for building commands.
func BoolPtr(b bool) *bool { return &b }

// Float64Ptr returns a pointer to a float64. Convenience for autoResumeSeconds.
func Float64Ptr(f float64) *float64 { return &f }

// PauseCmd builds a `pause` command with a finite auto-resume window.
func PauseCmd(autoResumeSeconds float64) Command {
	return Command{
		Cmd:               "pause",
		AutoResumeSeconds: Float64Ptr(autoResumeSeconds),
	}
}

// PauseIndefiniteCmd builds a `pause` command with no auto-resume timer.
func PauseIndefiniteCmd() Command {
	return Command{
		Cmd:        "pause",
		Indefinite: BoolPtr(true),
	}
}

// ResumeCmd builds a `resume` command.
func ResumeCmd() Command {
	return Command{Cmd: "resume"}
}

// DemarcateCmd builds a `demarcate` command (atomic session boundary).
func DemarcateCmd() Command {
	return Command{Cmd: "demarcate"}
}

// ReconfigureCmd builds a `reconfigure` command that toggles system-audio
// capture on the active session. The daemon performs an internal stop + start
// to apply the new capture-source configuration and persists
// `lastSystemAudioEnabled` so future auto-starts inherit the new value.
func ReconfigureCmd(systemAudio bool) Command {
	return Command{Cmd: "reconfigure", SystemAudio: BoolPtr(systemAudio)}
}
