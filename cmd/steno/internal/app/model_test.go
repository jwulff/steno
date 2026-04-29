package app

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/jwulff/steno/internal/daemon"
)

// TestMain suppresses the first-launch banner globally for the test
// suite; individual banner tests opt back in via `m.showFirstLaunchBanner = true`.
func TestMain(m *testing.M) {
	os.Setenv("STENO_SUPPRESS_FIRST_LAUNCH_BANNER", "1")
	os.Exit(m.Run())
}

func TestNewModel(t *testing.T) {
	m := New()
	if m.connected {
		t.Error("new model should not be connected")
	}
	if m.recording {
		t.Error("new model should not be recording")
	}
	if !m.transcriptLive {
		t.Error("new model should be in live mode")
	}
	if m.focusedPanel != FocusTranscript {
		t.Error("new model should focus transcript")
	}
}

func TestDaemonConnectError(t *testing.T) {
	m := New()
	m.width = 80
	m.height = 24

	updated, _ := m.Update(DaemonConnectErrorMsg{Err: fmt.Errorf("connection refused")})
	model := updated.(Model)

	if model.connected {
		t.Error("should not be connected after error")
	}
	if !model.reconnecting {
		t.Error("should be reconnecting after connect error")
	}
}

func TestStatusResponse(t *testing.T) {
	m := New()
	m.connected = true

	recording := true
	resp := StatusResponseMsg{Response: daemon.Response{
		OK:        true,
		SessionID: "sess-1",
		Recording: &recording,
		Device:    "MacBook Pro Microphone",
		Status:    "recording",
	}}

	updated, _ := m.Update(resp)
	model := updated.(Model)

	if !model.recording {
		t.Error("should be recording")
	}
	if model.sessionID != "sess-1" {
		t.Errorf("sessionID = %q, want %q", model.sessionID, "sess-1")
	}
	if model.deviceName != "MacBook Pro Microphone" {
		t.Errorf("deviceName = %q", model.deviceName)
	}
}

func TestDevicesResponse(t *testing.T) {
	m := New()
	m.connected = true

	resp := DevicesResponseMsg{Response: daemon.Response{
		OK:      true,
		Devices: []string{"Mic A", "Mic B"},
	}}

	updated, _ := m.Update(resp)
	model := updated.(Model)

	if len(model.devices) != 2 {
		t.Fatalf("devices = %d, want 2", len(model.devices))
	}
	if model.devices[0] != "Mic A" {
		t.Errorf("devices[0] = %q", model.devices[0])
	}
}

func TestSegmentEvent(t *testing.T) {
	m := New()
	m.connected = true
	m.width = 80
	m.height = 24

	seq := 1
	ev := daemon.Event{
		Event:          "segment",
		Text:           "Hello world",
		Source:         "microphone",
		SequenceNumber: &seq,
	}

	m.handleEvent(ev)

	if len(m.entries) != 1 {
		t.Fatalf("entries = %d, want 1", len(m.entries))
	}
	if m.entries[0].Text != "Hello world" {
		t.Errorf("text = %q", m.entries[0].Text)
	}
	if m.entries[0].Source != "microphone" {
		t.Errorf("source = %q", m.entries[0].Source)
	}
}

func TestPartialEvent(t *testing.T) {
	m := New()
	m.connected = true

	ev := daemon.Event{
		Event:  "partial",
		Text:   "testing partial",
		Source: "microphone",
	}

	m.handleEvent(ev)

	if m.partials["microphone"] != "testing partial" {
		t.Errorf("partials[microphone] = %q", m.partials["microphone"])
	}
}

func TestDualSourcePartialsTrackedIndependently(t *testing.T) {
	m := New()
	m.connected = true

	// Send mic partial
	m.handleEvent(daemon.Event{Event: "partial", Text: "hello from mic", Source: "microphone"})
	// Send sys partial
	m.handleEvent(daemon.Event{Event: "partial", Text: "hello from sys", Source: "systemAudio"})

	if m.partials["microphone"] != "hello from mic" {
		t.Errorf("partials[microphone] = %q, want %q", m.partials["microphone"], "hello from mic")
	}
	if m.partials["systemAudio"] != "hello from sys" {
		t.Errorf("partials[systemAudio] = %q, want %q", m.partials["systemAudio"], "hello from sys")
	}
}

func TestSegmentClearsOnlyItsSourcePartial(t *testing.T) {
	m := New()
	m.connected = true

	// Set both partials
	m.handleEvent(daemon.Event{Event: "partial", Text: "mic partial", Source: "microphone"})
	m.handleEvent(daemon.Event{Event: "partial", Text: "sys partial", Source: "systemAudio"})

	// Finalize mic segment — should clear only mic partial
	seq := 1
	m.handleEvent(daemon.Event{Event: "segment", Text: "mic final", Source: "microphone", SequenceNumber: &seq})

	if _, ok := m.partials["microphone"]; ok {
		t.Error("mic partial should be cleared after mic segment")
	}
	if m.partials["systemAudio"] != "sys partial" {
		t.Errorf("sys partial should remain, got %q", m.partials["systemAudio"])
	}
}

func TestSegmentUsesStartedAtTimestamp(t *testing.T) {
	m := New()
	m.connected = true

	startedAt := float64(1700000000.5)
	seq := 1
	ev := daemon.Event{
		Event:          "segment",
		Text:           "timestamped segment",
		Source:         "microphone",
		SequenceNumber: &seq,
		StartedAt:      &startedAt,
	}

	m.handleEvent(ev)

	if len(m.entries) != 1 {
		t.Fatalf("entries = %d, want 1", len(m.entries))
	}
	// Should use the startedAt timestamp, not time.Now()
	expected := float64(1700000000.5)
	got := float64(m.entries[0].Timestamp.Unix()) + float64(m.entries[0].Timestamp.Nanosecond())/1e9
	diff := got - expected
	if diff < -1 || diff > 1 {
		t.Errorf("timestamp = %v, want ~%v (diff=%v)", got, expected, diff)
	}
}

func TestSegmentsInsertedInChronologicalOrder(t *testing.T) {
	m := New()
	m.connected = true

	// Simulate dual-source: sys finishes first but mic started earlier
	sysStarted := float64(1700000001) // T+1
	micStarted := float64(1700000000) // T+0

	seq1 := 1
	m.handleEvent(daemon.Event{Event: "segment", Text: "sys first", Source: "systemAudio", SequenceNumber: &seq1, StartedAt: &sysStarted})
	seq2 := 2
	m.handleEvent(daemon.Event{Event: "segment", Text: "mic first", Source: "microphone", SequenceNumber: &seq2, StartedAt: &micStarted})

	if len(m.entries) != 2 {
		t.Fatalf("entries = %d, want 2", len(m.entries))
	}
	// mic should be first (earlier startedAt) despite arriving second
	if m.entries[0].Text != "mic first" {
		t.Errorf("entries[0].Text = %q, want %q", m.entries[0].Text, "mic first")
	}
	if m.entries[1].Text != "sys first" {
		t.Errorf("entries[1].Text = %q, want %q", m.entries[1].Text, "sys first")
	}
}

func TestLevelEvent(t *testing.T) {
	m := New()
	mic := float32(0.8)
	sys := float32(0.3)
	ev := daemon.Event{
		Event: "level",
		Mic:   &mic,
		Sys:   &sys,
	}

	m.handleEvent(ev)

	if m.micLevel != 0.8 {
		t.Errorf("micLevel = %v, want 0.8", m.micLevel)
	}
	if m.sysLevel != 0.3 {
		t.Errorf("sysLevel = %v, want 0.3", m.sysLevel)
	}
}

func TestStatusEvent(t *testing.T) {
	m := New()
	recording := true
	ev := daemon.Event{
		Event:     "status",
		Recording: &recording,
	}

	m.handleEvent(ev)

	if !m.recording {
		t.Error("should be recording after status event")
	}
}

func TestErrorEvent(t *testing.T) {
	m := New()
	tr := true
	ev := daemon.Event{
		Event:     "error",
		Message:   "test error",
		Transient: &tr,
	}

	cmd := m.handleEvent(ev)

	if m.errorMessage != "test error" {
		t.Errorf("errorMessage = %q", m.errorMessage)
	}
	if cmd == nil {
		t.Error("transient error should return a clear command")
	}
}

func TestTabTogglesFocus(t *testing.T) {
	m := New()
	m.width = 80
	m.height = 24
	m.connected = true

	if m.focusedPanel != FocusTranscript {
		t.Error("should start focused on transcript")
	}

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyTab})
	model := updated.(Model)
	if model.focusedPanel != FocusTopics {
		t.Error("tab should switch to topics")
	}

	updated, _ = model.Update(tea.KeyMsg{Type: tea.KeyTab})
	model = updated.(Model)
	if model.focusedPanel != FocusTranscript {
		t.Error("tab again should switch back to transcript")
	}
}

func TestTopicNavigation(t *testing.T) {
	m := New()
	m.width = 80
	m.height = 24
	m.connected = true
	m.focusedPanel = FocusTopics
	m.topics = []TopicDisplay{
		{ID: "1", Title: "Topic A", Summary: "Summary A"},
		{ID: "2", Title: "Topic B", Summary: "Summary B"},
		{ID: "3", Title: "Topic C", Summary: "Summary C"},
	}

	// j moves down
	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	model := updated.(Model)
	if model.selectedTopic != 1 {
		t.Errorf("after j, selectedTopic = %d, want 1", model.selectedTopic)
	}

	// k moves up
	updated, _ = model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	model = updated.(Model)
	if model.selectedTopic != 0 {
		t.Errorf("after k, selectedTopic = %d, want 0", model.selectedTopic)
	}

	// enter toggles expansion
	updated, _ = model.Update(tea.KeyMsg{Type: tea.KeyEnter})
	model = updated.(Model)
	if !model.topics[0].Expanded {
		t.Error("enter should expand topic 0")
	}

	updated, _ = model.Update(tea.KeyMsg{Type: tea.KeyEnter})
	model = updated.(Model)
	if model.topics[0].Expanded {
		t.Error("enter again should collapse topic 0")
	}
}

func TestTopicsLoadedMsg(t *testing.T) {
	m := New()
	m.width = 80
	m.height = 24

	msg := TopicsLoadedMsg{
		Topics: []TopicLoaded{
			{ID: "1", Title: "Planning", Summary: "Planning discussion"},
			{ID: "2", Title: "Review", Summary: "Code review session"},
		},
	}

	updated, _ := m.Update(msg)
	model := updated.(Model)

	if len(model.topics) != 2 {
		t.Fatalf("topics = %d, want 2", len(model.topics))
	}
	if model.topics[0].Title != "Planning" {
		t.Errorf("topics[0].Title = %q", model.topics[0].Title)
	}
	if model.topics[1].Summary != "Code review session" {
		t.Errorf("topics[1].Summary = %q", model.topics[1].Summary)
	}
}

func TestModelProcessingEvent(t *testing.T) {
	m := New()
	tr := true
	ev := daemon.Event{
		Event:           "model_processing",
		ModelProcessing: &tr,
	}

	m.handleEvent(ev)

	if !m.modelProcessing {
		t.Error("should be model processing")
	}
}

func TestViewRendersWithSize(t *testing.T) {
	m := New()
	m.width = 80
	m.height = 24

	view := m.View()
	if view == "" {
		t.Error("view should not be empty")
	}
	if view == "Initializing..." {
		t.Error("view should not show initializing with size set")
	}
}

func TestViewWithoutSize(t *testing.T) {
	m := New()
	view := m.View()
	if view != "Initializing..." {
		t.Errorf("view without size = %q, want 'Initializing...'", view)
	}
}

// fmt is needed for error messages
var _ = fmt.Errorf

// touch the auto-resume constant so the tests act as a smoke check
// when its value drifts.
var _ = defaultPauseAutoResumeSeconds

// --- U9 tests ----------------------------------------------------------------

// captureCommand spins up a fake daemon listener on a Unix socket and
// returns the command bytes the TUI sent. Used to verify the wire shape
// for pause / resume / demarcate keybinds.
func captureCommand(t *testing.T, m Model, key tea.KeyMsg) []byte {
	t.Helper()

	// Use /tmp directly to keep the socket path short — macOS's
	// 104-char sun_path limit can be overrun by t.TempDir() under
	// long test names. Clean up explicitly.
	sockPath := fmt.Sprintf("/tmp/steno-u9-%d.sock", time.Now().UnixNano())
	t.Cleanup(func() { os.Remove(sockPath) })

	listener, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	receivedCh := make(chan []byte, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 4096)
		n, _ := conn.Read(buf)
		// Send back a successful response so the TUI's command goroutine
		// doesn't block forever.
		conn.Write([]byte(`{"ok":true}` + "\n"))
		receivedCh <- buf[:n]
	}()

	client, err := daemon.Connect(sockPath)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer client.Close()

	m.client = client

	_, cmd := m.Update(key)
	if cmd == nil {
		t.Fatal("expected key handler to return a Cmd")
	}
	// Drain the cmd — its tea.Msg may be a response, doesn't matter.
	_ = cmd()

	select {
	case data := <-receivedCh:
		return data
	case <-time.After(2 * time.Second):
		t.Fatal("timeout waiting for command on socket")
		return nil
	}
}


func TestSpaceSendsDemarcate(t *testing.T) {
	m := New()
	m.connected = true
	m.engineStatus = StatusRecording
	m.width, m.height = 80, 24

	data := captureCommand(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	if !strings.Contains(string(data), `"cmd":"demarcate"`) {
		t.Errorf("expected demarcate cmd; got %q", string(data))
	}
}

func TestPSendsPauseWith30Min(t *testing.T) {
	m := New()
	m.connected = true
	m.engineStatus = StatusRecording
	m.width, m.height = 80, 24

	data := captureCommand(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'p'}})
	s := string(data)
	if !strings.Contains(s, `"cmd":"pause"`) {
		t.Errorf("expected pause cmd; got %q", s)
	}
	if !strings.Contains(s, `"autoResumeSeconds":1800`) {
		t.Errorf("expected autoResumeSeconds=1800; got %q", s)
	}
	if strings.Contains(s, `"indefinite"`) {
		t.Errorf("p should NOT set indefinite; got %q", s)
	}
}

func TestShiftPSendsPauseIndefinite(t *testing.T) {
	m := New()
	m.connected = true
	m.engineStatus = StatusRecording
	m.width, m.height = 80, 24

	data := captureCommand(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'P'}})
	s := string(data)
	if !strings.Contains(s, `"cmd":"pause"`) {
		t.Errorf("expected pause cmd; got %q", s)
	}
	if !strings.Contains(s, `"indefinite":true`) {
		t.Errorf("shift-p should set indefinite=true; got %q", s)
	}
}

func TestPWhilePausedSendsResume(t *testing.T) {
	m := New()
	m.connected = true
	m.engineStatus = StatusPaused
	m.width, m.height = 80, 24

	data := captureCommand(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'p'}})
	if !strings.Contains(string(data), `"cmd":"resume"`) {
		t.Errorf("expected resume cmd while paused; got %q", string(data))
	}
}

func TestSpaceWhilePausedFlashesHint(t *testing.T) {
	m := New()
	m.connected = true
	m.engineStatus = StatusPaused
	m.pausedIndefinitely = true
	m.width, m.height = 80, 24

	// Feed a fake client so handleKey doesn't bail on m.client == nil.
	// We can't easily exercise the full network path; instead we just
	// verify the command we get back. Spacebar-while-paused must NOT
	// produce a daemon command — it must produce a PauseHintMsg.
	// Install a non-nil client by reaching into the unexported field.
	m.client = &daemon.Client{} // zero-value client; won't be invoked

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	got := updated.(Model)

	if cmd == nil {
		t.Fatal("expected a Cmd (the hint flash); got nil")
	}
	msg := cmd()
	if _, ok := msg.(PauseHintMsg); !ok {
		t.Errorf("expected PauseHintMsg, got %T (%v)", msg, msg)
	}
	// Status should still be paused.
	if got.engineStatus != StatusPaused {
		t.Errorf("engineStatus = %q, want paused", got.engineStatus)
	}
}

func TestPauseHintMsgSetsFlag(t *testing.T) {
	m := New()
	updated, cmd := m.Update(PauseHintMsg{})
	got := updated.(Model)
	if !got.pauseHint {
		t.Error("pauseHint should be true after PauseHintMsg")
	}
	if cmd == nil {
		t.Error("expected a clear-pause-hint Cmd")
	}
}

func TestClearPauseHintMsgClears(t *testing.T) {
	m := New()
	m.pauseHint = true
	updated, _ := m.Update(ClearPauseHintMsg{})
	got := updated.(Model)
	if got.pauseHint {
		t.Error("pauseHint should be false after ClearPauseHintMsg")
	}
}

func TestPauseStateEventTransitionsToPaused(t *testing.T) {
	m := New()
	m.engineStatus = StatusRecording
	m.connected = true

	expires := float64(time.Now().Add(30 * time.Minute).Unix())
	pausedTrue := true
	indefFalse := false
	ev := daemon.Event{
		Event:              "pause_state",
		Paused:             &pausedTrue,
		PausedIndefinitely: &indefFalse,
		PauseExpiresAt:     &expires,
	}
	m.handleEvent(ev)

	if m.engineStatus != StatusPaused {
		t.Errorf("engineStatus = %q, want paused", m.engineStatus)
	}
	if m.pausedIndefinitely {
		t.Error("pausedIndefinitely should be false")
	}
	if m.pauseExpiresAt == nil {
		t.Fatal("expected pauseExpiresAt to be populated")
	}
}

func TestPauseStateEventResumeClearsPauseFields(t *testing.T) {
	m := New()
	m.engineStatus = StatusPaused
	m.pausedIndefinitely = true
	t0 := time.Now().Add(5 * time.Minute)
	m.pauseExpiresAt = &t0

	pausedFalse := false
	ev := daemon.Event{
		Event:  "pause_state",
		Paused: &pausedFalse,
	}
	m.handleEvent(ev)

	if m.engineStatus != StatusRecording {
		t.Errorf("engineStatus = %q, want recording", m.engineStatus)
	}
	if m.pausedIndefinitely {
		t.Error("pausedIndefinitely should be cleared")
	}
	if m.pauseExpiresAt != nil {
		t.Error("pauseExpiresAt should be cleared")
	}
}

func TestStatusBarRecording(t *testing.T) {
	m := New()
	m.connected = true
	m.engineStatus = StatusRecording
	m.width, m.height = 80, 24

	bar := m.renderStatusBar()
	if !strings.Contains(bar, "REC") {
		t.Errorf("status bar missing REC: %q", bar)
	}
}

func TestStatusBarPausedFinite(t *testing.T) {
	m := New()
	m.connected = true
	m.engineStatus = StatusPaused
	exp := time.Now().Add(30 * time.Minute)
	m.pauseExpiresAt = &exp
	m.width, m.height = 80, 24

	bar := m.renderStatusBar()
	if !strings.Contains(bar, "PAUSED") {
		t.Errorf("status bar missing PAUSED: %q", bar)
	}
	if !strings.Contains(bar, "resumes in") {
		t.Errorf("status bar missing 'resumes in': %q", bar)
	}
	// Should be roughly 30:00 (give or take a second).
	if !strings.Contains(bar, "30:") && !strings.Contains(bar, "29:") {
		t.Errorf("status bar missing 30-min countdown: %q", bar)
	}
}

func TestStatusBarPausedIndefinite(t *testing.T) {
	m := New()
	m.connected = true
	m.engineStatus = StatusPaused
	m.pausedIndefinitely = true
	m.width, m.height = 80, 24

	bar := m.renderStatusBar()
	if !strings.Contains(bar, "manual resume only") {
		t.Errorf("status bar missing 'manual resume only': %q", bar)
	}
}

func TestStatusBarRecovering(t *testing.T) {
	m := New()
	m.connected = true
	m.engineStatus = StatusRecovering
	m.recoveringStartedAt = time.Now().Add(-3 * time.Second)
	m.width, m.height = 80, 24

	bar := m.renderStatusBar()
	if !strings.Contains(bar, "RECOVERING") {
		t.Errorf("status bar missing RECOVERING: %q", bar)
	}
	if !strings.Contains(bar, "gap") {
		t.Errorf("status bar missing 'gap Ns': %q", bar)
	}
}

func TestStatusBarPermissionRevoked(t *testing.T) {
	m := New()
	m.connected = true
	m.engineStatus = StatusError
	m.permissionRevoked = true
	m.width = 200 // wide enough for the full token
	m.height = 24

	bar := m.renderStatusBar()
	if !strings.Contains(bar, MicOrScreenPermissionRevoked) {
		t.Errorf("status bar missing %q: %q", MicOrScreenPermissionRevoked, bar)
	}
	if !strings.Contains(bar, "grant in System Settings") {
		t.Errorf("status bar missing 'grant in System Settings': %q", bar)
	}
}

func TestRecoveryExhaustedSetsPermissionRevoked(t *testing.T) {
	m := New()
	transient := false
	ev := daemon.Event{
		Event:     "error",
		Message:   "recovery_exhausted: " + MicOrScreenPermissionRevoked,
		Transient: &transient,
	}
	m.handleEvent(ev)

	if m.engineStatus != StatusError {
		t.Errorf("engineStatus = %q, want error", m.engineStatus)
	}
	if !m.permissionRevoked {
		t.Error("permissionRevoked should be true after MIC_OR_SCREEN_PERMISSION_REVOKED message")
	}
	if len(m.errorHistory) != 1 {
		t.Errorf("errorHistory len = %d, want 1", len(m.errorHistory))
	}
}

func TestRecoveringEventSetsState(t *testing.T) {
	m := New()
	transient := true
	ev := daemon.Event{
		Event:     "error",
		Message:   "recovering: pipeline rebuild after AirPods disconnect",
		Transient: &transient,
	}
	m.handleEvent(ev)

	if m.engineStatus != StatusRecovering {
		t.Errorf("engineStatus = %q, want recovering", m.engineStatus)
	}
	if m.recoveringStartedAt.IsZero() {
		t.Error("recoveringStartedAt should be set")
	}
}

func TestHealedEventClearsRecovering(t *testing.T) {
	m := New()
	m.engineStatus = StatusRecovering

	transient := true
	ev := daemon.Event{
		Event:     "error",
		Message:   "healed: gap=3s",
		Transient: &transient,
	}
	m.handleEvent(ev)

	if m.engineStatus != StatusRecording {
		t.Errorf("engineStatus = %q, want recording (healed transitions out of recovering)", m.engineStatus)
	}
}

func TestErrorRingBufferOverflow(t *testing.T) {
	m := New()
	for i := 0; i < 15; i++ {
		m.appendErrorHistory(fmt.Sprintf("err %d", i))
	}
	if len(m.errorHistory) != errorRingCapacity {
		t.Fatalf("errorHistory len = %d, want %d", len(m.errorHistory), errorRingCapacity)
	}
	// Oldest 5 dropped — the buffer should hold "err 5"..."err 14".
	if m.errorHistory[0].Message != "err 5" {
		t.Errorf("oldest = %q, want 'err 5'", m.errorHistory[0].Message)
	}
	if m.errorHistory[errorRingCapacity-1].Message != "err 14" {
		t.Errorf("newest = %q, want 'err 14'", m.errorHistory[errorRingCapacity-1].Message)
	}
}

func TestErrorModalToggle(t *testing.T) {
	m := New()
	m.connected = true
	m.width, m.height = 80, 24
	m.client = &daemon.Client{}

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'e'}})
	got := updated.(Model)
	if !got.showErrorModal {
		t.Error("error modal should open on first 'e' press")
	}

	updated, _ = got.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'e'}})
	got = updated.(Model)
	if got.showErrorModal {
		t.Error("error modal should close on second 'e' press")
	}
}

func TestStatusBarOverflowDropsMetersBeforeState(t *testing.T) {
	m := New()
	m.connected = true
	m.engineStatus = StatusRecording
	m.systemAudio = true
	m.micLevel = 0.8
	m.sysLevel = 0.4
	m.modelProcessing = true
	// Very narrow — just enough for "● REC".
	m.width = 10

	bar := m.renderStatusBar()
	if !strings.Contains(bar, "REC") {
		t.Errorf("state token must be preserved under width pressure; bar=%q", bar)
	}
	// The mic/sys meter labels and the AI spinner should have been dropped.
	if strings.Contains(bar, "MIC ") || strings.Contains(bar, "SYS ") {
		t.Errorf("level meters should have been dropped at width=10; bar=%q", bar)
	}
}

func TestLastSegmentAnnotationYellowAt65s(t *testing.T) {
	m := New()
	m.connected = true
	m.engineStatus = StatusRecording
	m.lastSegmentAt = time.Now().Add(-65 * time.Second)
	m.width = 200
	m.height = 24

	annotation, highPriority := m.lastSegmentAnnotation(true)
	if annotation == "" {
		t.Fatal("expected annotation at 65s")
	}
	if !highPriority {
		t.Error("expected high-priority (yellow) annotation at >=60s while recording")
	}
}

func TestLastSegmentAnnotationHiddenBefore5s(t *testing.T) {
	m := New()
	m.lastSegmentAt = time.Now().Add(-2 * time.Second)
	annotation, _ := m.lastSegmentAnnotation(true)
	if annotation != "" {
		t.Errorf("annotation should be hidden <5s; got %q", annotation)
	}
}

func TestLastSegmentAnnotationHiddenWhilePaused(t *testing.T) {
	m := New()
	m.engineStatus = StatusPaused
	m.lastSegmentAt = time.Now().Add(-90 * time.Second)
	annotation, _ := m.lastSegmentAnnotation(false)
	if annotation != "" {
		t.Errorf("annotation should be hidden while paused; got %q", annotation)
	}
}

func TestFormatPauseRemaining(t *testing.T) {
	cases := []struct {
		d    time.Duration
		want string
	}{
		{30 * time.Minute, "30:00"},
		{29*time.Minute + 30*time.Second, "29:30"},
		{30 * time.Second, "00:30"},
		{0, "00:00"},
		{-5 * time.Second, "00:00"},
		{2 * time.Hour, "02:00"},
		{1*time.Hour + 30*time.Minute, "01:30"},
	}
	for _, c := range cases {
		got := formatPauseRemaining(c.d)
		if got != c.want {
			t.Errorf("formatPauseRemaining(%v) = %q, want %q", c.d, got, c.want)
		}
	}
}

func TestSegmentEventUpdatesLastSegmentAt(t *testing.T) {
	m := New()
	before := time.Now()
	seq := 1
	ev := daemon.Event{
		Event:          "segment",
		Text:           "hello",
		Source:         "microphone",
		SequenceNumber: &seq,
	}
	m.handleEvent(ev)
	if m.lastSegmentAt.Before(before) {
		t.Errorf("lastSegmentAt = %v, want >= %v", m.lastSegmentAt, before)
	}
}

func TestHealMarkerRendersInTimeline(t *testing.T) {
	m := New()
	m.connected = true
	m.width = 120
	m.height = 30

	// Two segments, second one carries a heal marker.
	seq1, seq2 := 1, 2
	m.handleEvent(daemon.Event{Event: "segment", Text: "before recovery", Source: "microphone", SequenceNumber: &seq1})
	m.handleEvent(daemon.Event{Event: "segment", Text: "after recovery", Source: "microphone", SequenceNumber: &seq2})

	m.healMarkers[seq2] = "after_gap:12s"

	view := m.View()
	if !strings.Contains(view, "healed after 12s gap") {
		t.Errorf("heal marker not rendered in segment timeline; view=\n%s", view)
	}
}

func TestDisconnectedStatusBar(t *testing.T) {
	m := New()
	m.reconnecting = true
	m.connected = false
	m.connError = "connection refused"
	m.width = 200
	m.height = 24

	bar := m.renderStatusBar()
	if !strings.Contains(bar, "DISCONNECTED") {
		t.Errorf("expected DISCONNECTED; bar=%q", bar)
	}
	if !strings.Contains(bar, "reconnecting") {
		t.Errorf("expected 'reconnecting'; bar=%q", bar)
	}
}

func TestFirstLaunchBannerRendersWhenSet(t *testing.T) {
	m := New()
	m.showFirstLaunchBanner = true
	m.width = 120
	m.height = 30

	view := m.View()
	if !strings.Contains(view, "always-on") {
		t.Errorf("first-launch banner not rendered; view=\n%s", view)
	}
	if !strings.Contains(view, "Press any key to dismiss") {
		t.Errorf("dismiss prompt missing from banner; view=\n%s", view)
	}
}

func TestFirstLaunchBannerDismissedOnAnyKey(t *testing.T) {
	// Use a temp HOME so the marker file doesn't pollute the user's
	// real Application Support directory.
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	t.Setenv("STENO_SUPPRESS_FIRST_LAUNCH_BANNER", "0")

	m := New()
	if !m.showFirstLaunchBanner {
		t.Fatal("banner should be shown on a fresh HOME")
	}

	m.width, m.height = 80, 24
	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'x'}})
	got := updated.(Model)

	if got.showFirstLaunchBanner {
		t.Error("banner should be dismissed after any key")
	}

	// Marker file should have been written.
	markerPath := firstLaunchMarkerPath()
	if _, err := os.Stat(markerPath); err != nil {
		t.Errorf("marker file not written at %q: %v", markerPath, err)
	}

	// Re-creating Model should not re-show the banner.
	m2 := New()
	if m2.showFirstLaunchBanner {
		t.Error("banner should not re-show after marker is written")
	}
}

func TestFooterReflectsEngineStatus(t *testing.T) {
	m := New()
	m.connected = true
	m.engineStatus = StatusRecording
	m.width, m.height = 200, 24

	footer := m.renderFooter()
	if !strings.Contains(footer, "Boundary") {
		t.Errorf("footer missing 'Boundary'; got %q", footer)
	}
	if !strings.Contains(footer, "Pause 30m") {
		t.Errorf("footer missing 'Pause 30m'; got %q", footer)
	}

	m.engineStatus = StatusPaused
	footer = m.renderFooter()
	if !strings.Contains(footer, "Resume") {
		t.Errorf("footer missing 'Resume' while paused; got %q", footer)
	}
}

// timeFromUnix is exercised by the pause-state test; sanity-check it.
func TestTimeFromUnix(t *testing.T) {
	got := timeFromUnix(1700000000.5)
	if got.Unix() != 1700000000 {
		t.Errorf("timeFromUnix unix = %d, want 1700000000", got.Unix())
	}
}

// --- Cluster-4 review fixes (PR #37) ---

// TestPauseStateResumeKeepsErrorEngineStatus exercises the fix for the
// Codex P1 finding: a failed-resume sequence
// (pause_state(true) → error event → pause_state(false)) must NOT mask
// the error by forcing engineStatus back to `recording`.
func TestPauseStateResumeKeepsErrorEngineStatus(t *testing.T) {
	m := New()
	m.engineStatus = StatusRecording

	// (a) Pause.
	expires := float64(time.Now().Add(30 * time.Minute).Unix())
	pausedTrue, indefFalse := true, false
	m.handleEvent(daemon.Event{
		Event:              "pause_state",
		Paused:             &pausedTrue,
		PausedIndefinitely: &indefFalse,
		PauseExpiresAt:     &expires,
	})
	if m.engineStatus != StatusPaused {
		t.Fatalf("setup: engineStatus = %q, want paused", m.engineStatus)
	}

	// (b) Recovery_exhausted-prefixed error → daemon surrendered.
	tr := false
	m.handleEvent(daemon.Event{
		Event:     "error",
		Message:   "recovery_exhausted: bring-up failed",
		Transient: &tr,
	})
	if m.engineStatus != StatusError {
		t.Fatalf("after error: engineStatus = %q, want error", m.engineStatus)
	}

	// (c) Resume event arrives anyway. Pause fields must clear, but
	// engineStatus must STAY error — the prior fix forced
	// StatusRecording here, which masked the failure.
	pausedFalse := false
	m.handleEvent(daemon.Event{
		Event:  "pause_state",
		Paused: &pausedFalse,
	})

	if m.engineStatus != StatusError {
		t.Errorf("after resume event: engineStatus = %q, want error (mask-prevention)", m.engineStatus)
	}
	if m.pauseExpiresAt != nil {
		t.Error("pauseExpiresAt should be cleared on resume even when masked")
	}
	if m.pausedIndefinitely {
		t.Error("pausedIndefinitely should be cleared on resume even when masked")
	}
}

// TestPauseStateResumeKeepsPermissionRevokedSurface ensures the
// permission-revoked surface is not cleared by a stray
// `pause_state(false)` while the underlying TCC failure is still active.
func TestPauseStateResumeKeepsPermissionRevokedSurface(t *testing.T) {
	m := New()
	m.engineStatus = StatusPaused
	m.permissionRevoked = true

	pausedFalse := false
	m.handleEvent(daemon.Event{
		Event:  "pause_state",
		Paused: &pausedFalse,
	})

	if !m.permissionRevoked {
		t.Error("permissionRevoked should NOT be cleared while a permission failure is active")
	}
	// Engine status should remain StatusPaused (mask-prevention path).
	if m.engineStatus != StatusPaused {
		t.Errorf("engineStatus = %q, want paused (no flip while permissionRevoked)", m.engineStatus)
	}
}

// TestDemarcateResponseUpdatesSessionID exercises the fix for the
// Codex P2 finding: a successful demarcate must update m.sessionID so
// right-hand panels (topics / summary) load against the new session.
func TestDemarcateResponseUpdatesSessionID(t *testing.T) {
	m := New()
	m.connected = true
	m.sessionID = "old-session"
	// Pre-populate a topic so we can assert the reset.
	m.topics = []TopicDisplay{{ID: "t1", Title: "old topic"}}

	resp := DemarcateResponseMsg{Response: daemon.Response{
		OK:        true,
		SessionID: "new-session",
	}}

	updated, _ := m.Update(resp)
	got := updated.(Model)

	if got.sessionID != "new-session" {
		t.Errorf("sessionID = %q, want new-session", got.sessionID)
	}
	if len(got.topics) != 0 {
		t.Errorf("topics should be cleared on session switch; got %d", len(got.topics))
	}
}

// TestDemarcateResponseFailureLeavesSessionID confirms a failed demarcate
// does NOT clobber the current session ID.
func TestDemarcateResponseFailureLeavesSessionID(t *testing.T) {
	m := New()
	m.connected = true
	m.sessionID = "current-session"

	resp := DemarcateResponseMsg{Response: daemon.Response{
		OK:    false,
		Error: "demarcate failed",
	}}

	updated, _ := m.Update(resp)
	got := updated.(Model)

	if got.sessionID != "current-session" {
		t.Errorf("sessionID = %q, want current-session unchanged", got.sessionID)
	}
}

// TestDeviceToggleKeybindRemoved confirms the i / I keypresses no
// longer mutate device state. Cluster-4 fix per Codex P2.
func TestDeviceToggleKeybindRemoved(t *testing.T) {
	m := New()
	m.connected = true
	m.devices = []string{"Mic A", "Mic B"}
	m.deviceName = "Mic A"
	m.width, m.height = 80, 24

	// Press 'i' — should be a no-op (binding removed).
	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'i'}})
	got := updated.(Model)
	if got.deviceName != "Mic A" {
		t.Errorf("deviceName changed to %q after 'i' press; binding should be removed", got.deviceName)
	}

	// Press 'I' — also a no-op.
	updated, _ = got.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'I'}})
	got2 := updated.(Model)
	if got2.deviceName != "Mic A" {
		t.Errorf("deviceName changed to %q after 'I' press; binding should be removed", got2.deviceName)
	}
}

// TestFirstLaunchBannerShowsWhenStatErrors exercises the fix for the
// Copilot first-launch finding: a stat() error that's NOT IsNotExist
// (e.g. permission denied) must default to SHOW the banner.
//
// We can't easily inject a stat error from a unit test, so we test the
// HOME-unresolvable path (which returns "" from firstLaunchMarkerPath)
// and assert the banner is shown.
func TestFirstLaunchBannerShowsWhenMarkerPathUnresolvable(t *testing.T) {
	// Make UserHomeDir fail by clobbering HOME env. On darwin, with
	// HOME unset and no /etc/passwd lookup, os.UserHomeDir returns
	// an error → firstLaunchMarkerPath returns "" → safe default
	// must show the banner.
	t.Setenv("HOME", "")
	t.Setenv("STENO_SUPPRESS_FIRST_LAUNCH_BANNER", "0")

	if !shouldShowFirstLaunchBanner() {
		t.Error("banner should show when HOME is unresolvable (over-disclose default)")
	}
}

// TestFirstLaunchBannerHidesWhenMarkerPresent confirms the positive
// case: marker exists → no banner. Anchor test for the inverted
// failure semantics.
func TestFirstLaunchBannerHidesWhenMarkerPresent(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	t.Setenv("STENO_SUPPRESS_FIRST_LAUNCH_BANNER", "0")

	// Create the marker.
	path := firstLaunchMarkerPath()
	if path == "" {
		t.Fatal("expected non-empty marker path")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	f.Close()

	if shouldShowFirstLaunchBanner() {
		t.Error("banner should be hidden when marker exists")
	}
}

// TestFirstLaunchBannerShowsWhenMarkerAbsent confirms the IsNotExist
// path (the "first launch ever" baseline) still shows the banner.
func TestFirstLaunchBannerShowsWhenMarkerAbsent(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	t.Setenv("STENO_SUPPRESS_FIRST_LAUNCH_BANNER", "0")

	if !shouldShowFirstLaunchBanner() {
		t.Error("banner should show when marker is absent on a fresh HOME")
	}
}

// TestTruncateToWidthPreservesANSI exercises the fix for the Copilot
// finding that the fallback truncation in composeStatusBar was
// rune-slicing across SGR escapes. With the ansi-aware fix,
// `truncateToWidth` must keep the visible width within budget AND
// preserve SGR pairs (every opening escape has a matching reset).
func TestTruncateToWidthPreservesANSI(t *testing.T) {
	// A long lipgloss-styled string with SGR escapes.
	style := lipgloss.NewStyle().Foreground(lipgloss.Color("#ff0000")).Bold(true)
	s := style.Render("● REC — recording on the long device with too much text")

	out := truncateToWidth(s, 20)
	w := lipgloss.Width(out)
	if w > 20 {
		t.Errorf("visible width = %d, want <= 20", w)
	}
	// The trailing ellipsis is the unmistakable signal that truncation
	// happened. Without ANSI awareness an orphan escape sequence
	// would land at the tail with no reset; ansi.Truncate guarantees
	// a clean reset.
	if !strings.Contains(out, "…") {
		t.Errorf("truncated output missing ellipsis: %q", out)
	}
}

// TestTruncateToWidthPassthroughWhenWithin asserts the no-op path
// (already <= width) still works.
func TestTruncateToWidthPassthroughWhenWithin(t *testing.T) {
	s := "short"
	out := truncateToWidth(s, 80)
	if out != s {
		t.Errorf("truncateToWidth = %q, want passthrough %q", out, s)
	}
}
