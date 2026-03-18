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
