package app

import (
	"strings"
	"testing"

	"github.com/jwulff/steno/internal/daemon"
)

// --- #62 model_status: Model state updates ---------------------------------

func TestModelStatusTranscriptionPreparing(t *testing.T) {
	m := New()
	m.handleEvent(daemon.Event{
		Event:     "model_status",
		Component: "transcription",
		State:     "preparing",
	})
	if m.transcriptionState != ModelStatePreparing {
		t.Errorf("transcriptionState = %q, want %q", m.transcriptionState, ModelStatePreparing)
	}
	if m.transcriptionReason != "" {
		t.Errorf("transcriptionReason = %q, want empty", m.transcriptionReason)
	}
	// Diarization untouched.
	if m.diarizationState != "" {
		t.Errorf("diarizationState = %q, want empty", m.diarizationState)
	}
}

func TestModelStatusTranscriptionUnavailableCapturesReason(t *testing.T) {
	const reason = "On-device transcription isn't available on this Mac. It requires Apple silicon with a 16-core (or larger) Neural Engine."
	m := New()
	m.handleEvent(daemon.Event{
		Event:     "model_status",
		Component: "transcription",
		State:     "unavailable",
		Reason:    reason,
	})
	if m.transcriptionState != ModelStateUnavailable {
		t.Errorf("transcriptionState = %q, want %q", m.transcriptionState, ModelStateUnavailable)
	}
	if m.transcriptionReason != reason {
		t.Errorf("transcriptionReason = %q, want %q", m.transcriptionReason, reason)
	}
}

func TestModelStatusTranscriptionReadyClearsPreparing(t *testing.T) {
	m := New()
	m.handleEvent(daemon.Event{Event: "model_status", Component: "transcription", State: "preparing"})
	m.handleEvent(daemon.Event{Event: "model_status", Component: "transcription", State: "ready"})
	if m.transcriptionState != ModelStateReady {
		t.Errorf("transcriptionState = %q, want %q", m.transcriptionState, ModelStateReady)
	}
}

func TestModelStatusTranscriptionReadyClearsUnavailableReason(t *testing.T) {
	m := New()
	m.handleEvent(daemon.Event{
		Event: "model_status", Component: "transcription", State: "unavailable",
		Reason: "no Neural Engine",
	})
	m.handleEvent(daemon.Event{Event: "model_status", Component: "transcription", State: "ready"})
	if m.transcriptionState != ModelStateReady {
		t.Errorf("transcriptionState = %q, want %q", m.transcriptionState, ModelStateReady)
	}
	if m.transcriptionReason != "" {
		t.Errorf("transcriptionReason should be cleared on ready, got %q", m.transcriptionReason)
	}
}

func TestModelStatusDiarizationPreparing(t *testing.T) {
	m := New()
	m.handleEvent(daemon.Event{Event: "model_status", Component: "diarization", State: "preparing"})
	if m.diarizationState != ModelStatePreparing {
		t.Errorf("diarizationState = %q, want %q", m.diarizationState, ModelStatePreparing)
	}
	// Transcription untouched.
	if m.transcriptionState != "" {
		t.Errorf("transcriptionState = %q, want empty", m.transcriptionState)
	}
}

func TestModelStatusDiarizationUnavailableCapturesReason(t *testing.T) {
	const reason = "Speaker diarization model unavailable on this Mac."
	m := New()
	m.handleEvent(daemon.Event{
		Event: "model_status", Component: "diarization", State: "unavailable", Reason: reason,
	})
	if m.diarizationState != ModelStateUnavailable {
		t.Errorf("diarizationState = %q, want %q", m.diarizationState, ModelStateUnavailable)
	}
	if m.diarizationReason != reason {
		t.Errorf("diarizationReason = %q, want %q", m.diarizationReason, reason)
	}
}

func TestModelStatusDiarizationReadyClearsState(t *testing.T) {
	m := New()
	m.handleEvent(daemon.Event{Event: "model_status", Component: "diarization", State: "preparing"})
	m.handleEvent(daemon.Event{Event: "model_status", Component: "diarization", State: "ready"})
	if m.diarizationState != ModelStateReady {
		t.Errorf("diarizationState = %q, want %q", m.diarizationState, ModelStateReady)
	}
	if m.diarizationReason != "" {
		t.Errorf("diarizationReason = %q, want empty", m.diarizationReason)
	}
}

// Components are tracked independently — a diarization event must not
// clobber transcription state and vice versa.
func TestModelStatusComponentsTrackedIndependently(t *testing.T) {
	m := New()
	m.handleEvent(daemon.Event{Event: "model_status", Component: "transcription", State: "ready"})
	m.handleEvent(daemon.Event{Event: "model_status", Component: "diarization", State: "preparing"})

	if m.transcriptionState != ModelStateReady {
		t.Errorf("transcriptionState = %q, want %q", m.transcriptionState, ModelStateReady)
	}
	if m.diarizationState != ModelStatePreparing {
		t.Errorf("diarizationState = %q, want %q", m.diarizationState, ModelStatePreparing)
	}
}

// An unknown component is ignored (forward-compatibility — a future
// daemon may add Layer C).
func TestModelStatusUnknownComponentIgnored(t *testing.T) {
	m := New()
	m.handleEvent(daemon.Event{Event: "model_status", Component: "translation", State: "preparing"})
	if m.transcriptionState != "" || m.diarizationState != "" {
		t.Errorf("unknown component should not touch known state: transcription=%q diarization=%q",
			m.transcriptionState, m.diarizationState)
	}
}

// --- #62 model_status: rendering -------------------------------------------

// Transcription unavailable renders the prominent, persistent banner with
// the reason text.
func TestViewRendersTranscriptionUnavailableBanner(t *testing.T) {
	const reason = "On-device transcription isn't available on this Mac. It requires Apple silicon with a 16-core (or larger) Neural Engine."
	m := New()
	m.connected = true
	m.width, m.height = 100, 30
	m.handleEvent(daemon.Event{
		Event: "model_status", Component: "transcription", State: "unavailable", Reason: reason,
	})

	view := m.View()
	if !strings.Contains(view, "can't transcribe") {
		t.Errorf("View() missing transcription-unavailable headline; got:\n%s", view)
	}
	// The daemon-supplied reason must be surfaced (at least the
	// distinctive 'Neural Engine' phrase survives word-wrapping).
	if !strings.Contains(view, "Neural Engine") {
		t.Errorf("View() missing reason text; got:\n%s", view)
	}
}

// The banner clears once transcription is ready.
func TestViewBannerClearsWhenTranscriptionReady(t *testing.T) {
	m := New()
	m.connected = true
	m.width, m.height = 100, 30
	m.handleEvent(daemon.Event{
		Event: "model_status", Component: "transcription", State: "unavailable",
		Reason: "no Neural Engine",
	})
	m.handleEvent(daemon.Event{Event: "model_status", Component: "transcription", State: "ready"})

	if strings.Contains(m.View(), "can't transcribe") {
		t.Errorf("View() still shows unavailable banner after ready; got:\n%s", m.View())
	}
}

// Transcription "preparing" shows the subtle status-bar indicator, not the
// prominent banner.
func TestStatusBarTranscriptionPreparingHint(t *testing.T) {
	m := New()
	m.connected = true
	m.width, m.height = 120, 24
	m.handleEvent(daemon.Event{Event: "model_status", Component: "transcription", State: "preparing"})

	bar := m.renderStatusBar()
	if !strings.Contains(bar, "Preparing transcription model") {
		t.Errorf("status bar missing transcription-preparing hint: %q", bar)
	}
}

// Diarization "preparing" shows a subtle speaker-labels hint.
func TestStatusBarDiarizationPreparingHint(t *testing.T) {
	m := New()
	m.connected = true
	m.width, m.height = 120, 24
	m.handleEvent(daemon.Event{Event: "model_status", Component: "diarization", State: "preparing"})

	bar := m.renderStatusBar()
	if !strings.Contains(bar, "Preparing speaker labels") {
		t.Errorf("status bar missing diarization-preparing hint: %q", bar)
	}
}

// Diarization "unavailable" shows a subtle, non-alarming hint — NOT a
// prominent banner (speaker labels are soft).
func TestStatusBarDiarizationUnavailableHint(t *testing.T) {
	m := New()
	m.connected = true
	m.width, m.height = 120, 24
	m.handleEvent(daemon.Event{
		Event: "model_status", Component: "diarization", State: "unavailable",
		Reason: "model not present",
	})

	bar := m.renderStatusBar()
	if !strings.Contains(bar, "Speaker labels unavailable") {
		t.Errorf("status bar missing diarization-unavailable hint: %q", bar)
	}
	// Soft case: must NOT trigger the prominent transcription banner.
	if strings.Contains(m.View(), "can't transcribe") {
		t.Errorf("diarization unavailable must not show the transcription banner; got:\n%s", m.View())
	}
}

// Transcription "preparing" takes precedence over diarization hints in the
// subtle status-bar line (the transcript coming online matters more).
func TestStatusBarTranscriptionPreparingBeatsDiarizationHint(t *testing.T) {
	m := New()
	m.connected = true
	m.width, m.height = 120, 24
	m.handleEvent(daemon.Event{Event: "model_status", Component: "diarization", State: "preparing"})
	m.handleEvent(daemon.Event{Event: "model_status", Component: "transcription", State: "preparing"})

	bar := m.renderStatusBar()
	if !strings.Contains(bar, "Preparing transcription model") {
		t.Errorf("status bar should prefer transcription-preparing hint: %q", bar)
	}
	if strings.Contains(bar, "Preparing speaker labels") {
		t.Errorf("status bar should not show diarization hint while transcription is preparing: %q", bar)
	}
}
