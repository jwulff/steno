package db

import (
	"fmt"
	"testing"
	"time"
)

func TestSegmentsForRange(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()

	now := float64(time.Now().Unix())

	rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, status, createdAt)
		VALUES ('sess-1', 'en_US', ?, 'active', ?)`, now, now)

	for i := 1; i <= 5; i++ {
		rawDB.Exec(`INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt, source)
			VALUES (?, 'sess-1', ?, ?, ?, ?, ?, 'microphone')`,
			fmt.Sprintf("seg-%d", i), fmt.Sprintf("Segment %d text", i), now, now+1, i, now)
	}

	store := &Store{db: rawDB}

	segments, err := store.SegmentsForRange("sess-1", 2, 4)
	if err != nil {
		t.Fatalf("SegmentsForRange: %v", err)
	}
	if len(segments) != 3 {
		t.Fatalf("got %d segments, want 3", len(segments))
	}
	if segments[0].Text != "Segment 2 text" {
		t.Errorf("segments[0].Text = %q, want %q", segments[0].Text, "Segment 2 text")
	}
	if segments[2].SequenceNumber != 4 {
		t.Errorf("segments[2].SequenceNumber = %d, want 4", segments[2].SequenceNumber)
	}
}

func TestLatestSummary(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()

	now := float64(time.Now().Unix())

	rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, status, createdAt)
		VALUES ('sess-1', 'en_US', ?, 'active', ?)`, now, now)

	rawDB.Exec(`INSERT INTO summaries (id, sessionId, content, summaryType, segmentRangeStart, segmentRangeEnd, modelId, createdAt)
		VALUES ('sum-1', 'sess-1', 'First summary', 'rolling', 1, 5, 'model-1', ?)`, now)
	rawDB.Exec(`INSERT INTO summaries (id, sessionId, content, summaryType, segmentRangeStart, segmentRangeEnd, modelId, createdAt)
		VALUES ('sum-2', 'sess-1', 'Latest summary', 'rolling', 1, 10, 'model-1', ?)`, now+10)

	store := &Store{db: rawDB}

	summary, err := store.LatestSummary("sess-1")
	if err != nil {
		t.Fatalf("LatestSummary: %v", err)
	}
	if summary == nil {
		t.Fatal("expected summary, got nil")
	}
	if summary.Content != "Latest summary" {
		t.Errorf("Content = %q, want %q", summary.Content, "Latest summary")
	}
}

func TestLatestSummaryNone(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()

	store := &Store{db: rawDB}

	summary, err := store.LatestSummary("nonexistent")
	if err != nil {
		t.Fatalf("LatestSummary: %v", err)
	}
	if summary != nil {
		t.Errorf("expected nil, got summary %q", summary.ID)
	}
}

func TestTopicsForSessionEmpty(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()

	store := &Store{db: rawDB}

	topics, err := store.TopicsForSession("nonexistent")
	if err != nil {
		t.Fatalf("TopicsForSession: %v", err)
	}
	if len(topics) != 0 {
		t.Errorf("got %d topics, want 0", len(topics))
	}
}

func TestActiveSessionNone(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()

	now := float64(time.Now().Unix())
	rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, endedAt, status, createdAt)
		VALUES ('sess-1', 'en_US', ?, ?, 'completed', ?)`, now-100, now-50, now-100)

	store := &Store{db: rawDB}

	sess, err := store.ActiveSession()
	if err != nil {
		t.Fatalf("ActiveSession: %v", err)
	}
	if sess != nil {
		t.Errorf("expected nil, got session %q", sess.ID)
	}
}

// TestSegmentsForSessionExcludesDuplicates verifies the U9 default-filter:
// 5 mic segments marked as duplicates of 5 sys segments → default query
// returns 5 rows (the canonical sys segments), not 10.
func TestSegmentsForSessionExcludesDuplicates(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()

	now := float64(time.Now().Unix())

	rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, status, createdAt)
		VALUES ('sess-1', 'en_US', ?, 'active', ?)`, now, now)

	// 5 sys segments at seq 1..5
	for i := 1; i <= 5; i++ {
		rawDB.Exec(`INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt, source)
			VALUES (?, 'sess-1', ?, ?, ?, ?, ?, 'systemAudio')`,
			fmt.Sprintf("sys-%d", i),
			fmt.Sprintf("sys text %d", i),
			now+float64(i), now+float64(i)+1, i, now)
	}
	// 5 mic segments at seq 6..10, each duplicate_of the matching sys segment
	for i := 1; i <= 5; i++ {
		seq := i + 5
		rawDB.Exec(`INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt, source, duplicate_of, dedup_method)
			VALUES (?, 'sess-1', ?, ?, ?, ?, ?, 'microphone', ?, 'exact')`,
			fmt.Sprintf("mic-%d", i),
			fmt.Sprintf("sys text %d", i),
			now+float64(i), now+float64(i)+1, seq, now,
			fmt.Sprintf("sys-%d", i))
	}

	store := &Store{db: rawDB}

	segments, err := store.SegmentsForSession("sess-1", 100, 0)
	if err != nil {
		t.Fatalf("SegmentsForSession: %v", err)
	}
	if len(segments) != 5 {
		t.Fatalf("default-filter: got %d segments, want 5", len(segments))
	}
	for _, seg := range segments {
		if seg.Source != "systemAudio" {
			t.Errorf("expected only systemAudio canonical rows, got source=%q id=%q",
				seg.Source, seg.ID)
		}
	}

	// SessionCounts also respects the filter
	counts, err := store.SessionCounts("sess-1")
	if err != nil {
		t.Fatalf("SessionCounts: %v", err)
	}
	if counts.Segments != 5 {
		t.Errorf("counts.Segments = %d, want 5 (default-filter)", counts.Segments)
	}
}

// TestSegmentsForRangeExcludesDuplicates verifies the default-filter on
// the range query that the TUI uses for topic-segment expansion.
func TestSegmentsForRangeExcludesDuplicates(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()

	now := float64(time.Now().Unix())

	rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, status, createdAt)
		VALUES ('sess-1', 'en_US', ?, 'active', ?)`, now, now)

	// seq 1: sys (canonical)
	rawDB.Exec(`INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt, source)
		VALUES ('sys-1', 'sess-1', 'canonical', ?, ?, 1, ?, 'systemAudio')`, now, now+1, now)
	// seq 2: mic, duplicate of sys-1
	rawDB.Exec(`INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt, source, duplicate_of)
		VALUES ('mic-1', 'sess-1', 'canonical', ?, ?, 2, ?, 'microphone', 'sys-1')`, now, now+1, now)
	// seq 3: mic (canonical, no duplicate_of)
	rawDB.Exec(`INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt, source)
		VALUES ('mic-2', 'sess-1', 'unique', ?, ?, 3, ?, 'microphone')`, now+1, now+2, now+1)

	store := &Store{db: rawDB}

	segs, err := store.SegmentsForRange("sess-1", 1, 3)
	if err != nil {
		t.Fatalf("SegmentsForRange: %v", err)
	}
	if len(segs) != 2 {
		t.Fatalf("got %d, want 2 (mic-1 should be filtered)", len(segs))
	}
	if segs[0].ID != "sys-1" || segs[1].ID != "mic-2" {
		t.Errorf("segs = [%q, %q], want [sys-1, mic-2]", segs[0].ID, segs[1].ID)
	}
}

func TestLatestSession(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()

	now := float64(time.Now().Unix())

	rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, endedAt, status, createdAt)
		VALUES ('sess-old', 'en_US', ?, ?, 'completed', ?)`, now-200, now-150, now-200)
	rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, endedAt, status, createdAt)
		VALUES ('sess-new', 'en_US', ?, ?, 'completed', ?)`, now-50, now-10, now-50)

	store := &Store{db: rawDB}

	sess, err := store.LatestSession()
	if err != nil {
		t.Fatalf("LatestSession: %v", err)
	}
	if sess == nil {
		t.Fatal("expected session, got nil")
	}
	if sess.ID != "sess-new" {
		t.Errorf("session ID = %q, want %q", sess.ID, "sess-new")
	}
}
