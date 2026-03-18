package daemon

import (
	"encoding/json"
	"testing"
)

func TestCommandMarshalStart(t *testing.T) {
	sys := true
	cmd := Command{
		Cmd:         "start",
		Locale:      "en_US",
		Device:      "MacBook Pro Microphone",
		SystemAudio: &sys,
	}

	data, err := json.Marshal(cmd)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var got Command
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if got.Cmd != "start" {
		t.Errorf("cmd = %q, want %q", got.Cmd, "start")
	}
	if got.Locale != "en_US" {
		t.Errorf("locale = %q, want %q", got.Locale, "en_US")
	}
	if got.Device != "MacBook Pro Microphone" {
		t.Errorf("device = %q, want %q", got.Device, "MacBook Pro Microphone")
	}
	if got.SystemAudio == nil || !*got.SystemAudio {
		t.Errorf("systemAudio = %v, want true", got.SystemAudio)
	}
}

func TestCommandOmitsEmptyFields(t *testing.T) {
	cmd := Command{Cmd: "stop"}
	data, err := json.Marshal(cmd)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("unmarshal raw: %v", err)
	}

	if _, ok := raw["locale"]; ok {
		t.Error("stop command should omit locale")
	}
	if _, ok := raw["device"]; ok {
		t.Error("stop command should omit device")
	}
	if _, ok := raw["systemAudio"]; ok {
		t.Error("stop command should omit systemAudio")
	}
}

func TestCommandSubscribeWithEvents(t *testing.T) {
	cmd := Command{
		Cmd:    "subscribe",
		Events: []string{"partial", "segment", "level"},
	}

	data, err := json.Marshal(cmd)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var got Command
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if len(got.Events) != 3 {
		t.Errorf("events len = %d, want 3", len(got.Events))
	}
}

func TestResponseSuccess(t *testing.T) {
	j := `{"ok":true,"sessionId":"abc-123","recording":true}`

	var resp Response
	if err := json.Unmarshal([]byte(j), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if !resp.OK {
		t.Error("ok = false, want true")
	}
	if resp.SessionID != "abc-123" {
		t.Errorf("sessionId = %q, want %q", resp.SessionID, "abc-123")
	}
	if resp.Recording == nil || !*resp.Recording {
		t.Errorf("recording = %v, want true", resp.Recording)
	}
}

func TestResponseError(t *testing.T) {
	j := `{"ok":false,"error":"Microphone permission denied"}`

	var resp Response
	if err := json.Unmarshal([]byte(j), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if resp.OK {
		t.Error("ok = true, want false")
	}
	if resp.Error != "Microphone permission denied" {
		t.Errorf("error = %q, want %q", resp.Error, "Microphone permission denied")
	}
}

func TestResponseDevices(t *testing.T) {
	j := `{"ok":true,"devices":["MacBook Pro Microphone","External USB"]}`

	var resp Response
	if err := json.Unmarshal([]byte(j), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if len(resp.Devices) != 2 {
		t.Fatalf("devices len = %d, want 2", len(resp.Devices))
	}
	if resp.Devices[0] != "MacBook Pro Microphone" {
		t.Errorf("devices[0] = %q", resp.Devices[0])
	}
}

func TestEventPartial(t *testing.T) {
	j := `{"event":"partial","text":"hello world","source":"microphone"}`

	var ev Event
	if err := json.Unmarshal([]byte(j), &ev); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if ev.Event != "partial" {
		t.Errorf("event = %q, want %q", ev.Event, "partial")
	}
	if ev.Text != "hello world" {
		t.Errorf("text = %q, want %q", ev.Text, "hello world")
	}
	if ev.Source != "microphone" {
		t.Errorf("source = %q, want %q", ev.Source, "microphone")
	}
}

func TestEventLevel(t *testing.T) {
	j := `{"event":"level","mic":0.75,"sys":0.3}`

	var ev Event
	if err := json.Unmarshal([]byte(j), &ev); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if ev.Mic == nil || *ev.Mic != 0.75 {
		t.Errorf("mic = %v, want 0.75", ev.Mic)
	}
	if ev.Sys == nil || *ev.Sys != 0.3 {
		t.Errorf("sys = %v, want 0.3", ev.Sys)
	}
}

func TestEventSegment(t *testing.T) {
	j := `{"event":"segment","text":"Hello there","source":"microphone","sessionId":"sess-1","sequenceNumber":5}`

	var ev Event
	if err := json.Unmarshal([]byte(j), &ev); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if ev.SequenceNumber == nil || *ev.SequenceNumber != 5 {
		t.Errorf("sequenceNumber = %v, want 5", ev.SequenceNumber)
	}
	if ev.SessionID != "sess-1" {
		t.Errorf("sessionId = %q, want %q", ev.SessionID, "sess-1")
	}
}

func TestEventStatus(t *testing.T) {
	j := `{"event":"status","recording":true}`

	var ev Event
	if err := json.Unmarshal([]byte(j), &ev); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if ev.Recording == nil || !*ev.Recording {
		t.Errorf("recording = %v, want true", ev.Recording)
	}
}

func TestEventError(t *testing.T) {
	j := `{"event":"error","message":"Speech recognition failed","transient":true}`

	var ev Event
	if err := json.Unmarshal([]byte(j), &ev); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if ev.Message != "Speech recognition failed" {
		t.Errorf("message = %q", ev.Message)
	}
	if ev.Transient == nil || !*ev.Transient {
		t.Errorf("transient = %v, want true", ev.Transient)
	}
}

func TestEventModelProcessing(t *testing.T) {
	j := `{"event":"model_processing","modelProcessing":true}`

	var ev Event
	if err := json.Unmarshal([]byte(j), &ev); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if ev.ModelProcessing == nil || !*ev.ModelProcessing {
		t.Errorf("modelProcessing = %v, want true", ev.ModelProcessing)
	}
}

func TestEventTopics(t *testing.T) {
	j := `{"event":"topics","title":"Project Planning, Code Review"}`

	var ev Event
	if err := json.Unmarshal([]byte(j), &ev); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if ev.Title != "Project Planning, Code Review" {
		t.Errorf("title = %q", ev.Title)
	}
}

func TestBoolPtr(t *testing.T) {
	p := BoolPtr(true)
	if p == nil || !*p {
		t.Error("BoolPtr(true) should return pointer to true")
	}

	p = BoolPtr(false)
	if p == nil || *p {
		t.Error("BoolPtr(false) should return pointer to false")
	}
}
