package app

import (
	"context"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/jwulff/steno/internal/daemon"
	"github.com/jwulff/steno/internal/db"
	"github.com/jwulff/steno/internal/ui"

	tea "github.com/charmbracelet/bubbletea"
)

// PanelFocus tracks which panel has keyboard focus.
type PanelFocus int

const (
	FocusTopics PanelFocus = iota
	FocusTranscript
)

// EngineStatus mirrors the Swift `EngineStatus` enum at
// `daemon/Sources/StenoDaemon/Engine/RecordingEngineDelegate.swift`.
// Used by the U9 health-surface status bar.
type EngineStatus string

const (
	// StatusUnknown is the zero value (TUI hasn't seen a status yet).
	StatusUnknown    EngineStatus = ""
	StatusIdle       EngineStatus = "idle"
	StatusStarting   EngineStatus = "starting"
	StatusRecording  EngineStatus = "recording"
	StatusStopping   EngineStatus = "stopping"
	StatusError      EngineStatus = "error"
	StatusRecovering EngineStatus = "recovering"
	StatusPaused     EngineStatus = "paused"
)

// ErrorEntry captures one non-transient error for the U9 ring buffer.
// Errors are surfaced via the `e` keybind error-history modal.
type ErrorEntry struct {
	Timestamp time.Time
	Message   string
}

// errorRingCapacity bounds the in-memory ring buffer. Errors past this
// are dropped (no disk persistence — per "Refinements" plan section).
const errorRingCapacity = 10

// MIC_OR_SCREEN_PERMISSION_REVOKED is the load-bearing token the daemon
// emits in `recoveryExhausted` events for TCC-revoked mic / screen
// recording. The TUI surfaces a distinct "grant in System Settings"
// status when this token appears (R12 + Refinements consolidated states).
const MicOrScreenPermissionRevoked = "MIC_OR_SCREEN_PERMISSION_REVOKED"

// firstLaunchMarkerFile is the on-disk marker that suppresses the
// always-on consent banner after first dismissal. Lives in the same
// Application Support directory as the daemon socket and DB.
const firstLaunchMarkerFile = ".first_launch_seen"

// firstLaunchBanner is the explicit consent disclosure shown on first
// run when the marker file is absent. Adapted from the U9 plan section.
const firstLaunchBanner = "Steno is now always-on. Recording started. Press space to mark a session boundary, p to pause for 30 min, shift-p to pause indefinitely. Press any key to dismiss."

// defaultPauseAutoResumeSeconds is what the TUI sends with `p` (the
// short-press pause). 30 minutes — matches the daemon-side default in
// CommandDispatcher.defaultPauseAutoResumeSeconds (U10).
const defaultPauseAutoResumeSeconds = 1800

// TranscriptEntry is a finalized transcript line for display.
//
// `IsBoundary == true` marks a UI-only synthetic entry inserted when a
// successful demarcate response arrives — it has no DB row, no sequence
// number, and no source. The transcript renderer draws it as a
// horizontal rule with the boundary timestamp instead of the usual
// `[HH:MM:SS] [MIC]` segment line. Subsequent real segments append
// after it and render normally. See the `DemarcateResponseMsg` handler
// in `Update` for the insertion site, and `renderTranscriptPanel` for
// the visual treatment.
type TranscriptEntry struct {
	Text       string
	Source     string
	Timestamp  time.Time
	SeqNum     int
	IsBoundary bool
}

// TopicDisplay holds a topic for display in the topic panel.
type TopicDisplay struct {
	ID                string
	Title             string
	Summary           string
	SegmentRangeStart int
	SegmentRangeEnd   int
	Expanded          bool
	Segments          []TopicSegment // loaded on expand
}

// Model is the root bubbletea model for the steno TUI.
type Model struct {
	// Connection state
	client    *daemon.Client // command connection
	evClient  *daemon.Client // event subscription connection
	connected bool
	connError string

	// Recording state
	//
	// `recording` is retained for legacy paths (StatusResponseMsg etc.)
	// but the U9 status bar reads `engineStatus` first. The Swift daemon
	// only emits `recording: bool` on `event:"status"` today, so the
	// translation lives in handleEvent.
	recording   bool
	engineStatus EngineStatus
	sessionID   string
	deviceName  string
	systemAudio bool
	devices     []string

	// Pause state (U9 / U10 wire)
	pauseExpiresAt     *time.Time // nil for indefinite or not-paused
	pausedIndefinitely bool

	// Recovery tracking (U5 / U9). recoveringStartedAt records the
	// wall-clock when the daemon emitted `recovering: ...`; used for
	// the "gap Ns" countdown in the status bar.
	recoveringStartedAt time.Time

	// Permission-revoked surface (R12 + Refinements). Set when a
	// `recoveryExhausted` event mentions MIC_OR_SCREEN_PERMISSION_REVOKED
	// so the status bar can surface a distinct "grant in System Settings"
	// state. Cleared on next pause/resume or successful recovery.
	permissionRevoked bool

	// Last-segment indicator (R12). Tracks the wall-clock of the most
	// recent finalized segment so the status bar can render
	// "last segment Ns ago" with a yellow escalation at >=60s.
	lastSegmentAt time.Time

	// Transcript
	entries  []TranscriptEntry
	partials map[string]string // source -> partial text

	// Heal markers keyed by sequenceNumber (U9). The Swift
	// EventBroadcaster's `event:"segment"` payload doesn't currently
	// carry healMarker — this map is populated when the TUI reads from
	// the DB on `event:"healed"`, and rendered inline in the segment
	// timeline.
	healMarkers map[int]string

	// Audio levels
	micLevel float32
	sysLevel float32

	// Topics
	topics          []TopicDisplay
	selectedTopic   int
	modelProcessing bool

	// Summary
	summaryText string
	showSummary bool

	// UI state
	focusedPanel     PanelFocus
	width            int
	height           int
	transcriptScroll int
	transcriptLive   bool
	topicScroll      int

	// Errors
	errorMessage   string
	errorTransient bool

	// Error history ring buffer (U9 Refinements). Last 10 non-transient
	// errors. `e` keybind toggles a modal that lists them with timestamps.
	errorHistory   []ErrorEntry
	showErrorModal bool

	// Pause-hint flash (U9): "press p to resume first" shown after a
	// spacebar press while paused. Set by the key handler, cleared by
	// ClearPauseHintMsg after ~2s.
	pauseHint bool

	// First-launch consent banner. True when the marker file is absent;
	// dismissed by any keypress (which also writes the marker).
	showFirstLaunchBanner bool

	// Status
	statusText string

	// DB
	store *db.Store

	// Reconnect
	reconnecting     bool
	reconnectAttempt int
}

// New creates a new Model with default state.
//
// First-launch banner: stat the marker file (~/Library/Application
// Support/Steno/.first_launch_seen). If it doesn't exist, the banner
// is shown above the segment timeline until the user dismisses it.
func New() Model {
	m := Model{
		statusText:            "Connecting to steno-daemon...",
		transcriptLive:        true,
		focusedPanel:          FocusTranscript,
		partials:              make(map[string]string),
		healMarkers:           make(map[int]string),
		showFirstLaunchBanner: shouldShowFirstLaunchBanner(),
	}
	return m
}

// Init returns the initial command — connect to the daemon and start
// the per-second tick for status-bar countdown / last-seg-ago redraw.
func (m Model) Init() tea.Cmd {
	return tea.Batch(connectCmd(), statusTickCmd())
}

// shouldShowFirstLaunchBanner returns true when the marker file CANNOT
// be confirmed to exist. Any uncertainty — HOME unresolvable, stat
// returns a non-IsNotExist error (e.g. permission-denied), filesystem
// glitch — defaults to `true` (show banner). The banner is a privacy /
// consent surface for an always-on recorder; the safe default when in
// doubt is to over-disclose, never under-disclose.
//
// Returns `false` only when stat succeeds and the marker is positively
// present.
//
// `STENO_SUPPRESS_FIRST_LAUNCH_BANNER=1` short-circuits the check; tests
// set this so they don't need to mock the user's home directory.
func shouldShowFirstLaunchBanner() bool {
	if os.Getenv("STENO_SUPPRESS_FIRST_LAUNCH_BANNER") == "1" {
		return false
	}
	path := firstLaunchMarkerPath()
	if path == "" {
		// HOME unresolvable — over-disclose.
		return true
	}
	info, err := os.Stat(path)
	if err == nil && info != nil {
		// Marker positively exists; banner already dismissed previously.
		return false
	}
	// Either IsNotExist (first launch) or some other stat failure
	// (permission denied, transient FS error). Both paths over-disclose.
	return true
}

// firstLaunchMarkerPath returns the marker file path, or "" if HOME is
// unresolvable.
func firstLaunchMarkerPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "Steno", firstLaunchMarkerFile)
}

// writeFirstLaunchMarker creates the marker file on banner dismissal.
// Errors are silently ignored — the banner re-appearing on next launch
// is a tolerable failure mode.
func writeFirstLaunchMarker() {
	path := firstLaunchMarkerPath()
	if path == "" {
		return
	}
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	f, err := os.Create(path)
	if err != nil {
		return
	}
	_ = f.Close()
}

// connectCmd ensures the daemon is running and connects with two connections:
// one for commands, one for event subscription.
func connectCmd() tea.Cmd {
	return func() tea.Msg {
		// Ensure daemon is running (auto-start if needed)
		mgr := daemon.NewManager()
		if err := mgr.EnsureRunning(context.Background()); err != nil {
			return DaemonConnectErrorMsg{Err: err}
		}

		sockPath := daemon.SocketPath()
		client, err := daemon.Connect(sockPath)
		if err != nil {
			return DaemonConnectErrorMsg{Err: err}
		}
		evClient, err := daemon.Connect(sockPath)
		if err != nil {
			client.Close()
			return DaemonConnectErrorMsg{Err: err}
		}
		return DaemonConnectedMsg{Client: client, EvClient: evClient}
	}
}

// subscribeCmd sends a subscribe command on the event client and starts reading events.
func subscribeCmd(evClient *daemon.Client) tea.Cmd {
	return func() tea.Msg {
		_, err := evClient.SendCommand(daemon.Command{Cmd: "subscribe"})
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return readEventCmd(evClient)()
	}
}

// readEventCmd reads the next event from the event client.
func readEventCmd(evClient *daemon.Client) tea.Cmd {
	return func() tea.Msg {
		ev, err := evClient.ReadEvent()
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return DaemonEventMsg{Event: ev}
	}
}

// statusCmd fetches daemon status.
func statusCmd(client *daemon.Client) tea.Cmd {
	return func() tea.Msg {
		resp, err := client.SendCommand(daemon.Command{Cmd: "status"})
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return StatusResponseMsg{Response: resp}
	}
}

// devicesCmd fetches available devices.
func devicesCmd(client *daemon.Client) tea.Cmd {
	return func() tea.Msg {
		resp, err := client.SendCommand(daemon.Command{Cmd: "devices"})
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return DevicesResponseMsg{Response: resp}
	}
}

// startCmd sends a start recording command.
func startCmd(client *daemon.Client, device string, sysAudio bool) tea.Cmd {
	return func() tea.Msg {
		cmd := daemon.Command{
			Cmd:         "start",
			Device:      device,
			SystemAudio: daemon.BoolPtr(sysAudio),
		}
		resp, err := client.SendCommand(cmd)
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return StartResponseMsg{Response: resp}
	}
}

// stopCmd sends a stop recording command.
//
// Retained on the protocol surface (and in the TUI command sender) for
// scripting / diagnostic use; the U9 keybind no longer reaches it.
func stopCmd(client *daemon.Client) tea.Cmd {
	return func() tea.Msg {
		resp, err := client.SendCommand(daemon.Command{Cmd: "stop"})
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return StopResponseMsg{Response: resp}
	}
}

// pauseCmd sends a `pause` command with a finite auto-resume window. (U9)
func pauseCmd(client *daemon.Client, autoResumeSeconds float64) tea.Cmd {
	return func() tea.Msg {
		resp, err := client.SendCommand(daemon.PauseCmd(autoResumeSeconds))
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return PauseResponseMsg{Response: resp}
	}
}

// pauseIndefiniteCmd sends a `pause` command with no auto-resume. (U9)
func pauseIndefiniteCmd(client *daemon.Client) tea.Cmd {
	return func() tea.Msg {
		resp, err := client.SendCommand(daemon.PauseIndefiniteCmd())
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return PauseResponseMsg{Response: resp}
	}
}

// resumeCmd sends a `resume` command. (U9)
func resumeCmd(client *daemon.Client) tea.Cmd {
	return func() tea.Msg {
		resp, err := client.SendCommand(daemon.ResumeCmd())
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return PauseResponseMsg{Response: resp}
	}
}

// demarcateCmd sends a `demarcate` command (atomic session boundary). (U9)
func demarcateCmd(client *daemon.Client) tea.Cmd {
	return func() tea.Msg {
		resp, err := client.SendCommand(daemon.DemarcateCmd())
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return DemarcateResponseMsg{Response: resp}
	}
}

// clearPauseHintCmd clears the "press p to resume first" flash after 2s.
func clearPauseHintCmd() tea.Cmd {
	return tea.Tick(2*time.Second, func(time.Time) tea.Msg {
		return ClearPauseHintMsg{}
	})
}

// statusTickCmd schedules the next per-second status-bar redraw. The
// tick is what drives the pause-countdown and last-seg-ago UI updates
// when no upstream events arrive.
func statusTickCmd() tea.Cmd {
	return tea.Tick(time.Second, func(time.Time) tea.Msg {
		return StatusTickMsg{}
	})
}

// clearTransientErrorCmd fires after a delay to clear transient errors.
func clearTransientErrorCmd() tea.Cmd {
	return tea.Tick(5*time.Second, func(time.Time) tea.Msg {
		return ClearTransientErrorMsg{}
	})
}

// reconnectCmd schedules a reconnection attempt with exponential backoff.
func reconnectCmd(attempt int) tea.Cmd {
	delay := time.Duration(1<<min(attempt, 4)) * time.Second // 1s, 2s, 4s, 8s, 16s cap
	if delay > 30*time.Second {
		delay = 30 * time.Second
	}
	return tea.Tick(delay, func(time.Time) tea.Msg {
		return ReconnectTickMsg{}
	})
}

// loadTopicsCmd reads topics from SQLite for the given session.
func loadTopicsCmd(store *db.Store, sessionID string) tea.Cmd {
	return func() tea.Msg {
		topics, err := store.TopicsForSession(sessionID)
		if err != nil {
			return TopicsLoadedMsg{} // silently ignore DB errors
		}
		var loaded []TopicLoaded
		for _, t := range topics {
			loaded = append(loaded, TopicLoaded{
				ID:                t.ID,
				Title:             t.Title,
				Summary:           t.Summary,
				SegmentRangeStart: t.SegmentRangeStart,
				SegmentRangeEnd:   t.SegmentRangeEnd,
			})
		}
		return TopicsLoadedMsg{Topics: loaded}
	}
}

// loadTopicSegmentsCmd reads segments for a topic's range from SQLite.
func loadTopicSegmentsCmd(store *db.Store, sessionID, topicID string, start, end int) tea.Cmd {
	return func() tea.Msg {
		segments, err := store.SegmentsForRange(sessionID, start, end)
		if err != nil {
			return TopicSegmentsLoadedMsg{TopicID: topicID}
		}
		loaded := make([]TopicSegment, 0, len(segments))
		for _, s := range segments {
			loaded = append(loaded, TopicSegment{
				Text:   s.Text,
				Source: s.Source,
				SeqNum: s.SequenceNumber,
			})
		}
		return TopicSegmentsLoadedMsg{TopicID: topicID, Segments: loaded}
	}
}

// loadSummaryCmd reads the latest summary from SQLite.
func loadSummaryCmd(store *db.Store, sessionID string) tea.Cmd {
	return func() tea.Msg {
		summary, err := store.LatestSummary(sessionID)
		if err != nil || summary == nil {
			return SummaryLoadedMsg{}
		}
		return SummaryLoadedMsg{Content: summary.Content}
	}
}

// openStoreCmd opens the SQLite store.
func openStoreCmd() tea.Cmd {
	return func() tea.Msg {
		dbPath := db.DefaultDBPath()
		if p := os.Getenv("STENO_DB"); p != "" {
			dbPath = p
		}
		store, err := db.Open(dbPath)
		if err != nil {
			return nil // silently ignore if DB not available yet
		}
		return storeOpenedMsg{store: store}
	}
}

type storeOpenedMsg struct{ store *db.Store }

// Update processes messages and returns the updated model and any commands.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.KeyMsg:
		return m.handleKey(msg)

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case DaemonConnectedMsg:
		m.client = msg.Client
		m.evClient = msg.EvClient
		m.connected = true
		m.connError = ""
		m.reconnecting = false
		m.reconnectAttempt = 0
		m.statusText = "Connected"
		// Subscribe on event client, fetch status/devices on command client
		return m, tea.Batch(
			subscribeCmd(m.evClient),
			statusCmd(m.client),
			devicesCmd(m.client),
			openStoreCmd(),
		)

	case DaemonConnectErrorMsg:
		m.connected = false
		m.connError = msg.Err.Error()
		// If the daemon binary isn't found, don't reconnect — it's a fatal config error
		if strings.Contains(m.connError, "not found") {
			m.reconnecting = false
			m.statusText = "Daemon not found"
			return m, nil
		}
		m.reconnecting = true
		m.statusText = "Daemon not running. Reconnecting..."
		return m, reconnectCmd(m.reconnectAttempt)

	case StatusResponseMsg:
		r := msg.Response
		if r.Recording != nil {
			m.recording = *r.Recording
		}
		if r.SessionID != "" {
			m.sessionID = r.SessionID
		}
		if r.Device != "" {
			m.deviceName = r.Device
		}
		if r.SystemAudio != nil {
			m.systemAudio = *r.SystemAudio
		}
		if r.Status != "" {
			m.statusText = r.Status
			m.engineStatus = EngineStatus(r.Status)
		}
		// U10: status response carries pause-state on every status fetch
		// so a freshly-connected TUI sees the truth immediately.
		m.applyPauseFields(r.Paused, r.PausedIndefinitely, r.PauseExpiresAt)
		return m, nil

	case DevicesResponseMsg:
		if msg.Response.Devices != nil {
			m.devices = msg.Response.Devices
		}
		return m, nil

	case StartResponseMsg:
		r := msg.Response
		if r.OK {
			m.recording = true
			if r.SessionID != "" {
				m.sessionID = r.SessionID
			}
			m.statusText = "Recording"
		} else {
			m.errorMessage = r.Error
			m.errorTransient = true
			return m, clearTransientErrorCmd()
		}
		return m, nil

	case StopResponseMsg:
		r := msg.Response
		if r.OK {
			m.recording = false
			m.partials = make(map[string]string)
			m.statusText = "Idle"
		} else {
			m.errorMessage = r.Error
		}
		return m, nil

	case DaemonEventMsg:
		cmd := m.handleEvent(msg.Event)
		// Continue reading events on event client
		return m, tea.Batch(cmd, readEventCmd(m.evClient))

	case DaemonEventErrorMsg:
		m.connected = false
		m.connError = msg.Err.Error()
		m.statusText = "Disconnected. Reconnecting..."
		m.reconnecting = true
		if m.client != nil {
			m.client.Close()
			m.client = nil
		}
		if m.evClient != nil {
			m.evClient.Close()
			m.evClient = nil
		}
		return m, reconnectCmd(m.reconnectAttempt)

	case ReconnectTickMsg:
		m.reconnectAttempt++
		return m, connectCmd()

	case storeOpenedMsg:
		m.store = msg.store
		return m, nil

	case TopicsLoadedMsg:
		m.topics = m.topics[:0]
		for _, t := range msg.Topics {
			m.topics = append(m.topics, TopicDisplay{
				ID:                t.ID,
				Title:             t.Title,
				Summary:           t.Summary,
				SegmentRangeStart: t.SegmentRangeStart,
				SegmentRangeEnd:   t.SegmentRangeEnd,
			})
		}
		if m.selectedTopic >= len(m.topics) {
			m.selectedTopic = max(0, len(m.topics)-1)
		}
		return m, nil

	case TopicSegmentsLoadedMsg:
		for i := range m.topics {
			if m.topics[i].ID == msg.TopicID {
				m.topics[i].Segments = msg.Segments
				break
			}
		}
		return m, nil

	case SummaryLoadedMsg:
		m.summaryText = msg.Content
		return m, nil

	case ClearTransientErrorMsg:
		if m.errorTransient {
			m.errorMessage = ""
			m.errorTransient = false
		}
		return m, nil

	case PauseResponseMsg:
		// Pause / resume responses primarily flow through the
		// pause_state event; we only surface command-error feedback here.
		if !msg.Response.OK {
			m.appendErrorHistory(msg.Response.Error)
			m.errorMessage = msg.Response.Error
			m.errorTransient = true
			return m, clearTransientErrorCmd()
		}
		return m, nil

	case DemarcateResponseMsg:
		if !msg.Response.OK {
			m.appendErrorHistory(msg.Response.Error)
			m.errorMessage = msg.Response.Error
			m.errorTransient = true
			return m, clearTransientErrorCmd()
		}
		// Demarcate succeeded — the daemon opened a fresh active session.
		// Insert a UI-only boundary marker into the transcript so the
		// user gets immediate visible feedback that the spacebar press
		// landed; without this the timeline silently keeps appending
		// new segments below old ones with no perceptible boundary.
		//
		// The marker is purely visual: no DB row, no sequence number,
		// no source. Inserted at the END of `m.entries` at the time of
		// the response, since the boundary is logically at "now" when
		// the user pressed space. Subsequent segments will append after
		// it normally (U10's startedAt routing keeps the chronological
		// invariant — new segments have timestamps >= boundary time).
		//
		// Edge case: if the daemon was `recovering` when the demarcate
		// arrived, U10 documents the demarcate gets queued. We still
		// insert the marker now — when the queued demarcate eventually
		// applies, the marker is already in roughly the right place on
		// the timeline. Acceptable approximation.
		m.entries = append(m.entries, TranscriptEntry{
			Timestamp:  time.Now(),
			IsBoundary: true,
		})
		if m.transcriptLive {
			m.scrollToBottom()
		}

		// Update m.sessionID so right-hand panels (topics / summary) start
		// loading data for the NEW session instead of staying anchored to
		// the old one. Mirror the StartResponseMsg pattern (line ~585):
		// only overwrite when the response carries a non-empty sessionId.
		var cmds []tea.Cmd
		if msg.Response.SessionID != "" && msg.Response.SessionID != m.sessionID {
			m.sessionID = msg.Response.SessionID
			// Reset right-hand panels for the fresh session and trigger
			// reloads. Topics for a freshly-opened session are empty
			// initially, so the load is mostly to clear the prior
			// session's view; the daemon will emit a `topics` event when
			// the LLM finishes the first extraction.
			m.topics = m.topics[:0]
			m.selectedTopic = 0
			if m.store != nil {
				cmds = append(cmds, loadTopicsCmd(m.store, m.sessionID))
				if m.showSummary {
					cmds = append(cmds, loadSummaryCmd(m.store, m.sessionID))
				}
			}
		}
		// On success the daemon will also emit a fresh status / segment
		// stream against the new session.
		return m, tea.Batch(cmds...)

	case PauseHintMsg:
		m.pauseHint = true
		return m, clearPauseHintCmd()

	case ClearPauseHintMsg:
		m.pauseHint = false
		return m, nil

	case StatusTickMsg:
		// Schedule the next tick. The render is implicit — the next
		// view call recomputes the countdown / last-seg-ago against
		// the current wall clock.
		return m, statusTickCmd()
	}

	return m, nil
}

// applyPauseFields updates the pause-state fields from a response or
// `pause_state` event. Centralizing the logic keeps the indefinite-vs-
// finite distinction in one place.
func (m *Model) applyPauseFields(paused, indefinite *bool, expiresAt *float64) {
	if paused == nil {
		return
	}
	if *paused {
		m.engineStatus = StatusPaused
		if indefinite != nil && *indefinite {
			m.pausedIndefinitely = true
			m.pauseExpiresAt = nil
		} else {
			m.pausedIndefinitely = false
			if expiresAt != nil {
				t := timeFromUnix(*expiresAt)
				m.pauseExpiresAt = &t
			} else {
				m.pauseExpiresAt = nil
			}
		}
	} else {
		// Resumed. Always clear the pause-related fields, but be careful
		// about the engine-status transition: a resume can FAIL (the
		// daemon emits `error` then `pause_state(false)`). In that case
		// engineStatus has already moved to `StatusError` (or the model
		// has flagged `permissionRevoked`). Forcing `StatusRecording`
		// here would mask the failure — the TUI would display REC even
		// though the engine is broken.
		//
		// Resolution: clear `pausedIndefinitely` / `pauseExpiresAt`
		// unconditionally (the resume request was acknowledged either
		// way), but only flip to `StatusRecording` if we were sitting in
		// `StatusPaused` AND the model isn't already in a failed state.
		// The canonical recording flag continues to arrive via
		// `event:"status"`.
		m.pausedIndefinitely = false
		m.pauseExpiresAt = nil
		if m.engineStatus == StatusPaused && !m.permissionRevoked {
			m.engineStatus = StatusRecording
			// Pause/resume happy path clears any prior permission-
			// revoked surface so the user can re-test after granting
			// in System Settings.
			m.permissionRevoked = false
		}
	}
}

// timeFromUnix converts a Unix-seconds float (with sub-second fraction)
// to a time.Time. Mirrors db.timeFromUnix but kept private to app to
// avoid exporting the helper.
func timeFromUnix(ts float64) time.Time {
	sec, frac := math.Modf(ts)
	return time.Unix(int64(sec), int64(frac*1e9))
}

// appendErrorHistory inserts an entry in the ring buffer, dropping the
// oldest when at capacity. Empty messages are ignored.
func (m *Model) appendErrorHistory(message string) {
	if message == "" {
		return
	}
	entry := ErrorEntry{Timestamp: time.Now(), Message: message}
	if len(m.errorHistory) >= errorRingCapacity {
		// Drop oldest by shifting; ring buffer with bounded slice.
		copy(m.errorHistory, m.errorHistory[1:])
		m.errorHistory[len(m.errorHistory)-1] = entry
		return
	}
	m.errorHistory = append(m.errorHistory, entry)
}

// handleEvent processes a daemon event and returns any resulting command.
//
// Event types (mirrored from EventBroadcaster.swift):
//   - partial / level / segment / topics / model_processing — unchanged
//   - status (recording: bool) — translated to engineStatus
//   - pause_state (paused / pausedIndefinitely / pauseExpiresAt) — U10
//   - error with message containing "recovering: ..." — sets engineStatus
//     to StatusRecovering. The Swift side currently routes recovering /
//     healed / recoveryExhausted onto the .error wire channel with the
//     transient flag distinguishing surrender from in-progress recovery
//     (see EventBroadcaster.mapEvent comment about "U9 will introduce
//     dedicated wire-protocol fields"). Until that lands, we sniff the
//     message prefix.
func (m *Model) handleEvent(ev daemon.Event) tea.Cmd {
	switch ev.Event {
	case "partial":
		if ev.Text == "" {
			delete(m.partials, ev.Source)
		} else {
			m.partials[ev.Source] = ev.Text
		}

	case "segment":
		ts := time.Now()
		if ev.StartedAt != nil {
			ts = timeFromUnix(*ev.StartedAt)
		}
		entry := TranscriptEntry{
			Text:      ev.Text,
			Source:    ev.Source,
			Timestamp: ts,
		}
		if ev.SequenceNumber != nil {
			entry.SeqNum = *ev.SequenceNumber
		}
		// Insert in chronological order — segments may arrive out of speech order
		// when dual sources are active
		i := sort.Search(len(m.entries), func(j int) bool {
			return m.entries[j].Timestamp.After(ts)
		})
		m.entries = append(m.entries, TranscriptEntry{})
		copy(m.entries[i+1:], m.entries[i:])
		m.entries[i] = entry
		delete(m.partials, ev.Source)
		if m.transcriptLive {
			m.scrollToBottom()
		}
		m.lastSegmentAt = time.Now()

	case "level":
		if ev.Mic != nil {
			m.micLevel = *ev.Mic
		}
		if ev.Sys != nil {
			m.sysLevel = *ev.Sys
		}

	case "status":
		if ev.Recording != nil {
			m.recording = *ev.Recording
			if m.recording {
				m.statusText = "Recording"
				m.engineStatus = StatusRecording
				// Successful recording resumes clear permission-revoked.
				m.permissionRevoked = false
			} else {
				// Status with recording=false in the always-on world
				// most likely means paused. Don't blindly write "Idle"
				// over a known paused state.
				if m.engineStatus != StatusPaused {
					m.statusText = "Idle"
					m.engineStatus = StatusIdle
				}
				m.partials = make(map[string]string)
			}
		}

	case "pause_state":
		// U10's dedicated pause-state event — applyPauseFields handles
		// the indefinite / finite split and the resume transition.
		m.applyPauseFields(ev.Paused, ev.PausedIndefinitely, ev.PauseExpiresAt)

	case "model_processing":
		if ev.ModelProcessing != nil {
			m.modelProcessing = *ev.ModelProcessing
		}

	case "topics":
		if m.store != nil && m.sessionID != "" {
			return loadTopicsCmd(m.store, m.sessionID)
		}
		return nil

	case "error":
		// U5 recovering / healed / recoveryExhausted are currently
		// multiplexed onto the error wire channel. Sniff the message
		// prefix to route to the right TUI state.
		switch {
		case strings.HasPrefix(ev.Message, "recovering:"):
			m.engineStatus = StatusRecovering
			m.recoveringStartedAt = time.Now()
			// Treat as non-persistent — we don't show this in the
			// error bar, the status bar carries it.
			return nil

		case strings.HasPrefix(ev.Message, "healed:"):
			// The pipeline restart succeeded. If we're still in
			// recovering, drop back to recording. The next `status`
			// event will reaffirm.
			if m.engineStatus == StatusRecovering {
				m.engineStatus = StatusRecording
			}
			// Refresh segment list from the DB so heal_marker columns
			// arrive via SegmentsForRange / DB refresh paths. For now
			// the marker is just stamped on the next segment we see —
			// the DB read happens on topic expansion.
			return nil

		case strings.HasPrefix(ev.Message, "recovery_exhausted:"):
			m.engineStatus = StatusError
			m.errorMessage = ev.Message
			m.errorTransient = false
			m.appendErrorHistory(ev.Message)
			if strings.Contains(ev.Message, MicOrScreenPermissionRevoked) {
				m.permissionRevoked = true
			}
			return nil
		}

		// Generic error. Persist transient errors with the auto-clear,
		// add non-transient errors to the ring buffer.
		m.errorMessage = ev.Message
		if ev.Transient != nil && *ev.Transient {
			m.errorTransient = true
			return clearTransientErrorCmd()
		}
		m.errorTransient = false
		m.appendErrorHistory(ev.Message)
	}

	return nil
}

// handleKey processes key presses.
//
// First-launch banner intercepts ALL keypresses — any key dismisses it
// and writes the marker file. The intercept is intentionally lossy:
// the dismissing keypress does NOT also fire its usual binding, so the
// user can't accidentally start a recording action while still reading
// the banner.
func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if m.showFirstLaunchBanner {
		// q / ctrl+c still quit so the banner can't trap the user.
		switch msg.String() {
		case KeyQuit, KeyQuitUpper, KeyCtrlC:
			if m.client != nil {
				m.client.Close()
			}
			if m.evClient != nil {
				m.evClient.Close()
			}
			return m, tea.Quit
		}
		m.showFirstLaunchBanner = false
		writeFirstLaunchMarker()
		return m, nil
	}

	// Error modal intercepts e / esc to close.
	if m.showErrorModal {
		switch msg.String() {
		case KeyErrorHistory, KeyErrorHistoryUp, KeyEsc:
			m.showErrorModal = false
			return m, nil
		case KeyQuit, KeyQuitUpper, KeyCtrlC:
			if m.client != nil {
				m.client.Close()
			}
			if m.evClient != nil {
				m.evClient.Close()
			}
			return m, tea.Quit
		}
		// Other keys are no-ops while the modal is open.
		return m, nil
	}

	switch msg.String() {
	case KeyQuit, KeyQuitUpper, KeyCtrlC:
		if m.client != nil {
			m.client.Close()
		}
		if m.evClient != nil {
			m.evClient.Close()
		}
		return m, tea.Quit

	case KeySpace:
		// U9: spacebar = atomic session demarcate, never start/stop.
		if !m.connected || m.client == nil {
			return m, nil
		}
		if m.engineStatus == StatusPaused {
			// Flash a hint instead of sending the command — the
			// daemon would reject it anyway with
			// "press p to resume first" (CommandDispatcher).
			return m, func() tea.Msg { return PauseHintMsg{} }
		}
		// While recovering the daemon queues the demarcate (U10), so
		// it's safe to fire-and-forget.
		return m, demarcateCmd(m.client)

	case KeyPause:
		// U9: `p` toggles pause with 30-min auto-resume.
		if !m.connected || m.client == nil {
			return m, nil
		}
		if m.engineStatus == StatusPaused {
			return m, resumeCmd(m.client)
		}
		return m, pauseCmd(m.client, defaultPauseAutoResumeSeconds)

	case KeyPauseIndefinite:
		// U9: `shift-p` toggles pause indefinitely.
		if !m.connected || m.client == nil {
			return m, nil
		}
		if m.engineStatus == StatusPaused {
			return m, resumeCmd(m.client)
		}
		return m, pauseIndefiniteCmd(m.client)

	case KeyErrorHistory, KeyErrorHistoryUp:
		// U9: toggle error-history modal.
		m.showErrorModal = !m.showErrorModal
		return m, nil

	case "tab":
		if m.focusedPanel == FocusTopics {
			m.focusedPanel = FocusTranscript
		} else {
			m.focusedPanel = FocusTopics
		}
		return m, nil

	case "j":
		if m.focusedPanel == FocusTopics && len(m.topics) > 0 {
			if m.selectedTopic < len(m.topics)-1 {
				m.selectedTopic++
			}
		}
		return m, nil

	case "k":
		if m.focusedPanel == FocusTopics && len(m.topics) > 0 {
			if m.selectedTopic > 0 {
				m.selectedTopic--
			}
		}
		return m, nil

	case "enter":
		if m.focusedPanel == FocusTopics && m.selectedTopic < len(m.topics) {
			topic := &m.topics[m.selectedTopic]
			topic.Expanded = !topic.Expanded
			if topic.Expanded && topic.Segments == nil && m.store != nil && m.sessionID != "" {
				return m, loadTopicSegmentsCmd(m.store, m.sessionID, topic.ID,
					topic.SegmentRangeStart, topic.SegmentRangeEnd)
			}
		}
		return m, nil

	case "s", "S":
		m.showSummary = !m.showSummary
		if m.showSummary && m.store != nil && m.sessionID != "" {
			return m, loadSummaryCmd(m.store, m.sessionID)
		}
		return m, nil

	case "up":
		if m.focusedPanel == FocusTranscript {
			m.transcriptLive = false
			if m.transcriptScroll > 0 {
				m.transcriptScroll--
			}
		}
		return m, nil

	case "down":
		if m.focusedPanel == FocusTranscript {
			maxScroll := m.maxTranscriptScroll()
			m.transcriptScroll++
			if m.transcriptScroll >= maxScroll {
				m.transcriptScroll = maxScroll
				m.transcriptLive = true
			}
		}
		return m, nil

	// `i` / `I` (cycle input device) was removed in the cluster-4 review
	// pass — the keybind mutated `m.deviceIndex` / `m.deviceName` locally
	// but never sent a daemon command, so the displayed device drifted
	// from the active capture device. See `keymap.go` for rationale.
	//
	// `a` / `A` (toggle system-audio capture) was removed for the same
	// reason: it only flipped `m.systemAudio` locally and sent no
	// command. The daemon's capture configuration is set at startup
	// from `StenoSettings.lastSystemAudioEnabled` and is not toggleable
	// mid-flight. See `keymap.go` for rationale.
	}

	return m, nil
}

func (m *Model) scrollToBottom() {
	m.transcriptScroll = m.maxTranscriptScroll()
}

func (m Model) maxTranscriptScroll() int {
	totalLines := len(m.entries) + len(m.partials)
	visible := m.transcriptVisibleLines()
	if totalLines <= visible {
		return 0
	}
	return totalLines - visible
}

func (m Model) transcriptVisibleLines() int {
	if m.height == 0 {
		return 20
	}
	// Reserve: header(2) + status(1) + divider(1) + divider(1) + error(1) + footer(1) + padding
	reserved := 8
	return max(5, m.height-reserved)
}

func (m Model) topicPanelWidth() int {
	if m.width == 0 {
		return 30
	}
	return max(20, m.width*30/100)
}

func (m Model) transcriptPanelWidth() int {
	if m.width == 0 {
		return 60
	}
	return max(30, m.width-m.topicPanelWidth()-3)
}

// View renders the full TUI.
func (m Model) View() string {
	if m.width == 0 {
		return "Initializing..."
	}

	var sections []string

	// Header
	sections = append(sections, m.renderHeader())

	// Status bar
	sections = append(sections, m.renderStatusBar())

	// Divider
	sections = append(sections, ui.DividerStyle.Render(strings.Repeat("─", m.width)))

	// First-launch consent banner (above the segment timeline, per the
	// U9 plan section).
	if m.showFirstLaunchBanner {
		sections = append(sections, m.renderFirstLaunchBanner())
	}

	// Main content: topics | transcript
	sections = append(sections, m.renderMainContent())

	// Divider
	sections = append(sections, ui.DividerStyle.Render(strings.Repeat("─", m.width)))

	// Error modal (overlays the error bar — when the modal is open the
	// per-error message is visible inside it, not duplicated below).
	if m.showErrorModal {
		sections = append(sections, m.renderErrorModal())
	} else if m.errorMessage != "" {
		sections = append(sections, m.renderErrorBar())
	}

	// Footer
	sections = append(sections, m.renderFooter())

	return strings.Join(sections, "\n")
}

// renderFirstLaunchBanner shows the always-on consent disclosure.
func (m Model) renderFirstLaunchBanner() string {
	// Wrap the message to fit width. Use lipgloss border styling for
	// visual prominence.
	w := m.width - 4
	if w < 20 {
		w = 20
	}
	wrapped := wrapText(firstLaunchBanner, w)
	body := strings.Join(wrapped, "\n")
	return ui.FirstLaunchBannerStyle.Render(body)
}

// renderErrorModal renders the U9 error-history overlay.
func (m Model) renderErrorModal() string {
	if len(m.errorHistory) == 0 {
		body := ui.DimStyle.Render("No recent errors. (Press e or esc to close.)")
		return ui.ErrorModalStyle.Render(body)
	}
	var lines []string
	lines = append(lines, ui.ErrorStyle.Render(fmt.Sprintf("Error history (%d / %d)", len(m.errorHistory), errorRingCapacity)))
	for i := len(m.errorHistory) - 1; i >= 0; i-- {
		entry := m.errorHistory[i]
		ts := ui.TimestampStyle.Render(entry.Timestamp.Format("[15:04:05]"))
		lines = append(lines, ts+" "+ui.ErrorTextStyle.Render(entry.Message))
	}
	lines = append(lines, ui.DimStyle.Render("Press e or esc to close."))
	return ui.ErrorModalStyle.Render(strings.Join(lines, "\n"))
}

func (m Model) renderHeader() string {
	title := ui.TitleStyle.Render("STENO")

	var deviceInfo string
	if m.deviceName != "" {
		deviceInfo = ui.DimStyle.Render(" — " + m.deviceName)
	}

	var audioMode string
	if m.systemAudio {
		audioMode = ui.DimStyle.Render(" [MIC + SYS]")
	}

	return title + deviceInfo + audioMode
}

// renderStatusBar produces the U9 health-surface status bar. State
// label is highest priority; meters / spinner are the first to drop on
// narrow terminals (per the Refinements overflow policy).
func (m Model) renderStatusBar() string {
	state, isRecording := m.statusLabel()

	// Last-segment annotation. Computed even when zero so we can decide
	// whether to drop it under width pressure.
	lastSeg, lastSegPriority := m.lastSegmentAnnotation(isRecording)

	// Level meters. Only meaningful while recording or recovering.
	var meters string
	if isRecording {
		meters = renderLevelMeter("MIC", m.micLevel)
		if m.systemAudio {
			meters += "  " + renderLevelMeter("SYS", m.sysLevel)
		}
	}

	// AI processing spinner.
	var processing string
	if m.modelProcessing {
		processing = ui.SpinnerStyle.Render("⟳ AI")
	}

	// Pause hint flash (Spacebar-while-paused). Sits at the bottom of
	// the status bar but rendered inline here for compactness; clears
	// after ~2s.
	var hint string
	if m.pauseHint {
		hint = ui.DimStyle.Render("press p to resume first")
	}

	return composeStatusBar(state, lastSeg, lastSegPriority, meters, processing, hint, m.width)
}

// statusLabel returns the leading state token and whether the daemon is
// in a "recording-ish" state where level meters carry information.
//
// Priority order (per R12 + Refinements):
//  1. ● REC                                          → engineStatus=recording
//  2. ⏸ PAUSED — resumes in HH:MM (or MM:SS)         → engineStatus=paused, finite
//  3. ⏸ PAUSED — manual resume only                  → engineStatus=paused, indefinite
//  4. ⚠ RECOVERING — gap Ns                          → engineStatus=recovering
//  5. ✗ MIC_OR_SCREEN_PERMISSION_REVOKED — grant ... → permissionRevoked=true
//  6. ✗ FAILED — see error                           → engineStatus=error
//  7. ◌ DISCONNECTED — daemon socket lost, reconnecting → reconnecting=true
//  8. (fallback) idle / connecting…
func (m Model) statusLabel() (label string, recordingish bool) {
	// DISCONNECTED takes priority over any stale daemon-side state when
	// the TUI is in its reconnect backoff loop.
	if m.reconnecting || (!m.connected && m.connError != "") {
		return ui.DisconnectedStyle.Render("◌ DISCONNECTED — daemon socket lost, reconnecting"), false
	}
	if !m.connected {
		return ui.IdleDotStyle.Render("◌ Connecting…"), false
	}

	// Permission-revoked surface is a more-specific FAILED variant.
	if m.permissionRevoked {
		return ui.FailedStyle.Render("✗ "+MicOrScreenPermissionRevoked+" — grant in System Settings"), false
	}

	switch m.engineStatus {
	case StatusRecording:
		return ui.RecordingDotStyle.Render("● REC"), true

	case StatusPaused:
		if m.pausedIndefinitely {
			return ui.PausedStyle.Render("⏸ PAUSED — manual resume only"), false
		}
		if m.pauseExpiresAt != nil {
			remaining := time.Until(*m.pauseExpiresAt)
			if remaining < 0 {
				remaining = 0
			}
			return ui.PausedStyle.Render(fmt.Sprintf("⏸ PAUSED — resumes in %s", formatPauseRemaining(remaining))), false
		}
		// Paused but no expiry data yet (race between status fetch and
		// pause_state event). Render conservatively.
		return ui.PausedStyle.Render("⏸ PAUSED"), false

	case StatusRecovering:
		gap := time.Since(m.recoveringStartedAt)
		if m.recoveringStartedAt.IsZero() {
			gap = 0
		}
		secs := int(gap.Seconds())
		return ui.RecoveringStyle.Render(fmt.Sprintf("⚠ RECOVERING — gap %ds", secs)), true

	case StatusError:
		return ui.FailedStyle.Render("✗ FAILED — see error"), false

	case StatusStarting:
		return ui.IdleDotStyle.Render("◌ STARTING"), false

	case StatusStopping:
		return ui.IdleDotStyle.Render("◌ STOPPING"), false

	case StatusIdle, StatusUnknown:
		// Legacy `recording: bool` may still be the only signal we have
		// from a daemon that hasn't been re-built against U9's wire.
		if m.recording {
			return ui.RecordingDotStyle.Render("● REC"), true
		}
		return ui.IdleDotStyle.Render("○ IDLE"), false
	}

	return ui.IdleDotStyle.Render("○ " + string(m.engineStatus)), false
}

// formatPauseRemaining renders a duration as MM:SS for <1h windows and
// HH:MM for ≥1h. Negative durations clamp to 00:00.
func formatPauseRemaining(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	totalSecs := int(d.Seconds())
	if totalSecs < 3600 {
		return fmt.Sprintf("%02d:%02d", totalSecs/60, totalSecs%60)
	}
	hours := totalSecs / 3600
	minutes := (totalSecs % 3600) / 60
	return fmt.Sprintf("%02d:%02d", hours, minutes)
}

// lastSegmentAnnotation returns the "last segment Ns ago" suffix and a
// priority-tier (low / high). Empty string means don't render. Per R12
// the annotation only shows when ≥5s and turns yellow at ≥60s while
// not paused. Hidden entirely while paused (no audio is being captured).
func (m Model) lastSegmentAnnotation(isRecording bool) (text string, highPriority bool) {
	if m.engineStatus == StatusPaused {
		return "", false
	}
	if m.lastSegmentAt.IsZero() {
		return "", false
	}
	delta := time.Since(m.lastSegmentAt)
	if delta < 5*time.Second {
		return "", false
	}
	secs := int(delta.Seconds())
	label := fmt.Sprintf("last segment %ds ago", secs)
	if isRecording && delta >= 60*time.Second {
		return ui.LastSegWarnStyle.Render(label), true
	}
	return ui.DimStyle.Render(label), false
}

// composeStatusBar applies the status-bar overflow policy: state label
// is sticky; drop low-priority last-seg → level meters → spinner in
// that order if the assembled width exceeds the terminal width.
//
// Width=0 (no WindowSizeMsg yet) means render everything — no truncation.
//
// Hint sits on the right edge of the bar when present.
func composeStatusBar(state, lastSeg string, lastSegHigh bool, meters, processing, hint string, width int) string {
	parts := []string{state}
	suffixes := []string{} // appended after state, joined with "  "

	if lastSeg != "" {
		suffixes = append(suffixes, lastSeg)
	}
	if meters != "" {
		suffixes = append(suffixes, meters)
	}
	if processing != "" {
		suffixes = append(suffixes, processing)
	}
	if hint != "" {
		suffixes = append(suffixes, hint)
	}

	if width <= 0 {
		return strings.Join(append(parts, suffixes...), "  ")
	}

	// Drop priority order, lowest first:
	//   1. low-priority last-seg (only when the annotation is informational, not warning)
	//   2. level meters
	//   3. last-seg (high priority — yellow warn)
	//   4. AI processing spinner
	// We keep popping until the line fits.
	composed := func() string {
		return strings.Join(append([]string{state}, suffixes...), "  ")
	}
	for lipgloss.Width(composed()) > width && len(suffixes) > 0 {
		// Find the lowest-priority remaining suffix and drop it.
		idx := lowestPriorityIdx(suffixes, lastSeg, lastSegHigh, meters, processing, hint)
		if idx < 0 {
			break
		}
		suffixes = append(suffixes[:idx], suffixes[idx+1:]...)
	}

	out := composed()
	if lipgloss.Width(out) > width {
		// Last resort — truncate the state itself.
		out = truncateToWidth(out, width)
	}
	return out
}

// lowestPriorityIdx finds the index of the suffix to drop first under
// width pressure. Drop order:
//   1. last-seg when low-priority (informational only)
//   2. level meters
//   3. last-seg when high-priority (yellow warn)
//   4. processing spinner
//   5. hint (kept until last — it's transient information that informs
//      the user about a just-pressed key)
func lowestPriorityIdx(suffixes []string, lastSeg string, lastSegHigh bool, meters, processing, hint string) int {
	// Build an ordered list of the candidates we'd drop.
	for _, target := range []string{
		// 1. Low-priority last-seg.
		conditionalString(!lastSegHigh, lastSeg),
		// 2. Meters.
		meters,
		// 3. High-priority last-seg.
		conditionalString(lastSegHigh, lastSeg),
		// 4. Processing.
		processing,
	} {
		if target == "" {
			continue
		}
		for i, s := range suffixes {
			if s == target {
				return i
			}
		}
	}
	// Hint is preserved as long as anything else is droppable — but if
	// only the hint remains beyond state, drop it last.
	for i, s := range suffixes {
		if s == hint && hint != "" {
			return i
		}
	}
	return -1
}

func conditionalString(cond bool, s string) string {
	if cond {
		return s
	}
	return ""
}

func renderLevelMeter(label string, level float32) string {
	const barLen = 8
	filled := int(level * barLen)
	if filled > barLen {
		filled = barLen
	}

	var bar string
	for i := 0; i < barLen; i++ {
		if i < filled {
			pct := float32(i) / float32(barLen)
			if pct > 0.6 {
				bar += ui.LevelYellowStyle.Render("█")
			} else {
				bar += ui.LevelGreenStyle.Render("█")
			}
		} else {
			bar += ui.LevelGrayStyle.Render("░")
		}
	}

	var styledLabel string
	if label == "SYS" {
		styledLabel = ui.SysLabelStyle.Render(label)
	} else {
		styledLabel = ui.MicLabelStyle.Render(label)
	}
	return styledLabel + " " + bar
}

func (m Model) renderMainContent() string {
	topicW := m.topicPanelWidth()
	transcriptW := m.transcriptPanelWidth()
	contentH := m.transcriptVisibleLines()

	topicPanel := m.renderTopicPanel(topicW, contentH)
	transcriptPanel := m.renderTranscriptPanel(transcriptW, contentH)

	divider := ui.DividerStyle.Render("│")

	// Join panels side by side
	topicLines := strings.Split(topicPanel, "\n")
	transcriptLines := strings.Split(transcriptPanel, "\n")

	// Pad to same height
	for len(topicLines) < contentH {
		topicLines = append(topicLines, strings.Repeat(" ", topicW))
	}
	for len(transcriptLines) < contentH {
		transcriptLines = append(transcriptLines, "")
	}

	var rows []string
	for i := 0; i < contentH; i++ {
		tl := topicLines[i]
		tr := ""
		if i < len(transcriptLines) {
			tr = transcriptLines[i]
		}
		rows = append(rows, tl+divider+tr)
	}

	return strings.Join(rows, "\n")
}

func (m Model) renderTopicPanel(width, height int) string {
	// Header
	var header string
	if m.focusedPanel == FocusTopics {
		header = ui.PanelTitleActiveStyle.Render(fmt.Sprintf("TOPICS (%d)", len(m.topics)))
	} else {
		header = ui.PanelTitleStyle.Render(fmt.Sprintf("TOPICS (%d)", len(m.topics)))
	}
	header = padRight(header, width)

	var lines []string
	lines = append(lines, header)

	if len(m.topics) == 0 {
		lines = append(lines, ui.DimStyle.Render("  No topics yet..."))
		lines = append(lines, ui.DimStyle.Render("  Topics appear as you speak"))
	} else {
		for i, topic := range m.topics {
			isSelected := i == m.selectedTopic
			expandMarker := "▸"
			if topic.Expanded {
				expandMarker = "▾"
			}

			var line string
			if isSelected && m.focusedPanel == FocusTopics {
				line = ui.SelectedStyle.Render("> "+expandMarker+" ") + ui.SelectedStyle.Render(topic.Title)
			} else {
				line = "  " + expandMarker + " " + topic.Title
			}
			lines = append(lines, truncateToWidth(line, width))

			if topic.Expanded {
				// Summary
				wrapped := wrapText(topic.Summary, max(10, width-6))
				for _, wl := range wrapped {
					lines = append(lines, ui.DimStyle.Render("    "+wl))
				}
				// Segment range
				rangeText := fmt.Sprintf("    segments %d-%d", topic.SegmentRangeStart, topic.SegmentRangeEnd)
				lines = append(lines, ui.DimStyle.Render(rangeText))
				// Segments (if loaded)
				if len(topic.Segments) > 0 {
					for _, seg := range topic.Segments {
						srcLabel := "MIC"
						if seg.Source == "systemAudio" {
							srcLabel = "SYS"
						}
						prefix := fmt.Sprintf("      [%s] ", srcLabel)
						segWrapped := wrapText(seg.Text, max(10, width-len(prefix)-2))
						for j, sl := range segWrapped {
							if j == 0 {
								lines = append(lines, ui.DimStyle.Render(prefix+sl))
							} else {
								lines = append(lines, ui.DimStyle.Render(strings.Repeat(" ", len(prefix))+sl))
							}
						}
					}
				}
			}
		}
	}

	// Pad to height
	for len(lines) < height {
		lines = append(lines, strings.Repeat(" ", width))
	}
	if len(lines) > height {
		lines = lines[:height]
	}

	// Ensure each line is padded to width
	for i, l := range lines {
		lines[i] = padRight(l, width)
	}

	return strings.Join(lines, "\n")
}

func (m Model) renderTranscriptPanel(width, height int) string {
	// Header
	var header string
	var badge string
	if m.transcriptLive {
		badge = ui.LiveBadgeStyle.Render(" LIVE")
	} else {
		badge = ui.ScrollBadgeStyle.Render(" SCROLL")
	}

	if m.showSummary {
		badge = ui.MagentaStyle.Render(" SUMMARY")
	}

	if m.focusedPanel == FocusTranscript {
		header = ui.PanelTitleActiveStyle.Render("TRANSCRIPT") + badge
	} else {
		header = ui.PanelTitleStyle.Render("TRANSCRIPT") + badge
	}

	var lines []string
	lines = append(lines, header)

	contentHeight := height - 1 // subtract header line

	// Summary view overlay
	if m.showSummary {
		lines = append(lines, "")
		if m.summaryText == "" {
			lines = append(lines, ui.DimStyle.Render("  No summary yet."))
			lines = append(lines, ui.DimStyle.Render("  Summaries are generated as you speak."))
		} else {
			textWidth := max(10, width-4)
			wrapped := wrapText(m.summaryText, textWidth)
			for _, wl := range wrapped {
				lines = append(lines, "  "+wl)
			}
		}
		lines = append(lines, "")
		lines = append(lines, ui.DimStyle.Render("  Press s to return to transcript"))

		for len(lines) < height {
			lines = append(lines, strings.Repeat(" ", width))
		}
		if len(lines) > height {
			lines = lines[:height]
		}
		for i, l := range lines {
			lines[i] = padRight(l, width)
		}
		return strings.Join(lines, "\n")
	}

	if !m.connected {
		if m.reconnecting {
			lines = append(lines, "")
			lines = append(lines, ui.ErrorTextStyle.Render("  Daemon disconnected. Reconnecting..."))
			if m.connError != "" {
				lines = append(lines, ui.DimStyle.Render("  "+m.connError))
			}
		} else if m.connError != "" {
			lines = append(lines, "")
			lines = append(lines, ui.ErrorStyle.Render("  "+m.connError))
			lines = append(lines, ui.DimStyle.Render("  Install with: make install"))
		} else {
			lines = append(lines, ui.DimStyle.Render("  Connecting to steno-daemon..."))
		}
	} else if len(m.entries) == 0 && len(m.partials) == 0 {
		lines = append(lines, "")
		// U9: always-on — no longer prompt the user to "start recording".
		// The daemon is already capturing; this is just a cold transcript.
		lines = append(lines, ui.DimStyle.Render("  Listening… speak to see segments here."))
		lines = append(lines, ui.DimStyle.Render("  Press space to mark a session boundary, p to pause."))
	} else {
		// Build display lines from entries, wrapping long text
		// Prefix: "  [HH:MM:SS] [MIC] " = ~22 chars visible
		prefixWidth := 22
		textWidth := max(10, width-prefixWidth-2) // -2 for leading indent
		indentStr := strings.Repeat(" ", prefixWidth)

		var displayLines []string
		// Width budget for the boundary rule: the transcript panel is
		// `width` wide and the renderer indents each line by 2 spaces
		// in the wrapping pass below. Match that so the rule sits
		// flush with segment text.
		boundaryWidth := max(10, width-2)
		for _, e := range m.entries {
			// Synthetic session-boundary marker (UI-only, inserted on a
			// successful DemarcateResponseMsg). Rendered as a horizontal
			// rule with a timestamp. No source, no sequence number.
			if e.IsBoundary {
				displayLines = append(displayLines,
					renderSessionBoundary(e.Timestamp, boundaryWidth))
				continue
			}
			// U9: heal-marker annotation — rendered on its own line
			// BEFORE the segment so the user sees "⚠ healed after Ns
			// gap" between two adjacent segments. Marker is keyed by
			// the seqNum of the FIRST post-recovery segment.
			if marker, ok := m.healMarkers[e.SeqNum]; ok && marker != "" {
				displayLines = append(displayLines, ui.HealMarkerStyle.Render("  ⚠ "+formatHealMarker(marker)))
			}
			ts := ui.TimestampStyle.Render(e.Timestamp.Format("[15:04:05]"))
			var src string
			if e.Source == "systemAudio" {
				src = ui.SysLabelStyle.Render("[SYS] ")
			} else {
				src = ui.MicLabelStyle.Render("[MIC] ")
			}
			wrapped := wrapText(e.Text, textWidth)
			displayLines = append(displayLines, ts+" "+src+wrapped[0])
			for _, wl := range wrapped[1:] {
				displayLines = append(displayLines, indentStr+wl)
			}
		}

		// Partial text — render each source's partial as a separate line
		// Deterministic order: microphone first, then systemAudio
		for _, pSource := range []string{"microphone", "systemAudio"} {
			pText, ok := m.partials[pSource]
			if !ok {
				continue
			}
			ts := ui.TimestampStyle.Render(time.Now().Format("[15:04:05]"))
			src := ui.PartialTextStyle.Render("[MIC] ")
			if pSource == "systemAudio" {
				src = ui.PartialTextStyle.Render("[SYS] ")
			}
			wrapped := wrapText(pText+"▌", textWidth)
			partial := ui.PartialTextStyle.Render(wrapped[0])
			displayLines = append(displayLines, ts+" "+src+partial)
			for _, wl := range wrapped[1:] {
				displayLines = append(displayLines, indentStr+ui.PartialTextStyle.Render(wl))
			}
		}

		// Apply scroll
		start := 0
		if m.transcriptLive {
			if len(displayLines) > contentHeight {
				start = len(displayLines) - contentHeight
			}
		} else {
			start = m.transcriptScroll
		}
		if start < 0 {
			start = 0
		}

		end := start + contentHeight
		if end > len(displayLines) {
			end = len(displayLines)
		}

		for i := start; i < end; i++ {
			lines = append(lines, "  "+displayLines[i])
		}
	}

	// Pad to height
	for len(lines) < height {
		lines = append(lines, "")
	}
	if len(lines) > height {
		lines = lines[:height]
	}

	return strings.Join(lines, "\n")
}

func (m Model) renderErrorBar() string {
	return ui.ErrorStyle.Render("Error: ") + ui.ErrorTextStyle.Render(m.errorMessage)
}

func (m Model) renderFooter() string {
	var parts []string

	if m.connected {
		// U9: spacebar = demarcate, p / shift-p = pause toggles.
		parts = append(parts, ui.FooterKeyStyle.Render("Space")+ui.FooterDescStyle.Render(" Boundary"))
		if m.engineStatus == StatusPaused {
			parts = append(parts, ui.FooterKeyStyle.Render("p/P")+ui.FooterDescStyle.Render(" Resume"))
		} else {
			parts = append(parts, ui.FooterKeyStyle.Render("p")+ui.FooterDescStyle.Render(" Pause 30m"))
			parts = append(parts, ui.FooterKeyStyle.Render("P")+ui.FooterDescStyle.Render(" Pause"))
		}
		parts = append(parts, ui.FooterKeyStyle.Render("e")+ui.FooterDescStyle.Render(" Errors"))
		parts = append(parts, ui.FooterKeyStyle.Render("Tab")+ui.FooterDescStyle.Render(" Focus"))
		parts = append(parts, ui.FooterKeyStyle.Render("j/k")+ui.FooterDescStyle.Render(" Nav"))
		parts = append(parts, ui.FooterKeyStyle.Render("↑↓")+ui.FooterDescStyle.Render(" Scroll"))
		parts = append(parts, ui.FooterKeyStyle.Render("s")+ui.FooterDescStyle.Render(" Summary"))
	}

	parts = append(parts, ui.FooterKeyStyle.Render("q")+ui.FooterDescStyle.Render(" Quit"))

	return strings.Join(parts, "  ")
}

// Helpers

func padRight(s string, width int) string {
	// Get visible length (ignoring ANSI codes)
	visible := lipgloss.Width(s)
	if visible >= width {
		return s
	}
	return s + strings.Repeat(" ", width-visible)
}

// truncateToWidth shortens a (possibly ANSI-styled) string so its visible
// width is at most `width`, appending an ellipsis. Uses
// `ansi.Truncate` from `charmbracelet/x/ansi` so SGR escapes are
// preserved correctly — naive rune-slicing would chop mid-escape and
// emit orphan styling that bleeds into the rest of the line. The
// previous implementation (rune-slice + ellipsis) was the source of the
// cluster-4 review's "ANSI codes break under fallback truncation"
// finding.
func truncateToWidth(s string, width int) string {
	if width <= 0 {
		return ""
	}
	visible := lipgloss.Width(s)
	if visible <= width {
		return s
	}
	// `ansi.Truncate` accepts `length` as visible-cell count and an
	// optional tail string, total visible width = length + tail width.
	// We want the final visible width to equal `width`, so subtract the
	// tail's visible width. The ellipsis is one cell wide.
	const tail = "…"
	tailWidth := lipgloss.Width(tail)
	if width <= tailWidth {
		// Degenerate: the budget is too small for tail + at least one
		// content cell. Return just the tail (or empty if even the tail
		// doesn't fit).
		if width >= tailWidth {
			return tail
		}
		return ""
	}
	return ansi.Truncate(s, width-tailWidth, tail)
}

// renderSessionBoundary draws the UI-only session-boundary line shown
// in the transcript when a successful demarcate response arrives. The
// shape is `─── session boundary HH:MM:SS ───`, padded with em-dashes
// out to `width` cells. Matches the dim styling used for other
// non-segment annotations in the timeline (heal-marker, hint text).
func renderSessionBoundary(ts time.Time, width int) string {
	if width < 10 {
		width = 10
	}
	label := fmt.Sprintf(" session boundary %s ", ts.Format("15:04:05"))
	labelW := lipgloss.Width(label)
	if labelW >= width {
		// Pathologically narrow — return the label truncated, no rules.
		return ui.DimStyle.Render(truncateToWidth(label, width))
	}
	pad := width - labelW
	left := pad / 2
	right := pad - left
	rule := strings.Repeat("─", left) + label + strings.Repeat("─", right)
	return ui.DimStyle.Render(rule)
}

// formatHealMarker renders the SegmentsForRange-returned heal marker
// (e.g. "after_gap:12s") as a friendly user-facing annotation.
func formatHealMarker(marker string) string {
	const prefix = "after_gap:"
	if strings.HasPrefix(marker, prefix) {
		return "healed after " + strings.TrimPrefix(marker, prefix) + " gap"
	}
	return "healed: " + marker
}

func wrapText(text string, width int) []string {
	if width <= 0 {
		return []string{text}
	}

	var lines []string
	for _, paragraph := range strings.Split(text, "\n") {
		var current string
		for _, word := range strings.Fields(paragraph) {
			if current == "" {
				current = word
			} else if len(current)+1+len(word) <= width {
				current += " " + word
			} else {
				lines = append(lines, current)
				current = word
			}
		}
		if current != "" {
			lines = append(lines, current)
		} else {
			lines = append(lines, "")
		}
	}
	if len(lines) == 0 {
		return []string{""}
	}
	return lines
}
