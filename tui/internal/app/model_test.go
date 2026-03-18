package app

import (
	"fmt"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/jwulff/steno/tui/internal/daemon"
)

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
