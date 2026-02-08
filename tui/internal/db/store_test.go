package db

import (
	"database/sql"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

// createTestDB creates an in-memory SQLite database with the steno schema.
func createTestDB(t *testing.T) *sql.DB {
	t.Helper()

	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	schema := `
		CREATE TABLE sessions (
			id TEXT PRIMARY KEY,
			locale TEXT NOT NULL,
			startedAt REAL NOT NULL,
			endedAt REAL,
			title TEXT,
			status TEXT NOT NULL DEFAULT 'active',
			createdAt REAL NOT NULL
		);

		CREATE TABLE segments (
			id TEXT PRIMARY KEY,
			sessionId TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
			text TEXT NOT NULL,
			startedAt REAL NOT NULL,
			endedAt REAL NOT NULL,
			confidence REAL,
			sequenceNumber INTEGER NOT NULL,
			createdAt REAL NOT NULL,
			source TEXT NOT NULL DEFAULT 'microphone',
			UNIQUE(sessionId, sequenceNumber)
		);

		CREATE TABLE topics (
			id TEXT PRIMARY KEY,
			sessionId TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
			title TEXT NOT NULL,
			summary TEXT NOT NULL,
			segmentRangeStart INTEGER NOT NULL,
			segmentRangeEnd INTEGER NOT NULL,
			createdAt REAL NOT NULL
		);

		CREATE TABLE summaries (
			id TEXT PRIMARY KEY,
			sessionId TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
			content TEXT NOT NULL,
			summaryType TEXT NOT NULL,
			segmentRangeStart INTEGER NOT NULL,
			segmentRangeEnd INTEGER NOT NULL,
			modelId TEXT NOT NULL,
			createdAt REAL NOT NULL
		);
	`
	if _, err := db.Exec(schema); err != nil {
		t.Fatalf("create schema: %v", err)
	}

	return db
}

func TestTopicsForSession(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()

	now := float64(time.Now().Unix())

	// Insert a session
	rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, status, createdAt)
		VALUES ('sess-1', 'en_US', ?, 'active', ?)`, now, now)

	// Insert topics
	rawDB.Exec(`INSERT INTO topics (id, sessionId, title, summary, segmentRangeStart, segmentRangeEnd, createdAt)
		VALUES ('t-1', 'sess-1', 'Project Planning', 'Discussion about project milestones', 1, 5, ?)`, now)
	rawDB.Exec(`INSERT INTO topics (id, sessionId, title, summary, segmentRangeStart, segmentRangeEnd, createdAt)
		VALUES ('t-2', 'sess-1', 'Code Review', 'Reviewing the auth module changes', 6, 10, ?)`, now)

	store := &Store{db: rawDB}

	topics, err := store.TopicsForSession("sess-1")
	if err != nil {
		t.Fatalf("TopicsForSession: %v", err)
	}

	if len(topics) != 2 {
		t.Fatalf("got %d topics, want 2", len(topics))
	}

	if topics[0].Title != "Project Planning" {
		t.Errorf("topics[0].Title = %q, want %q", topics[0].Title, "Project Planning")
	}
	if topics[1].Title != "Code Review" {
		t.Errorf("topics[1].Title = %q, want %q", topics[1].Title, "Code Review")
	}
	if topics[0].SegmentRangeStart != 1 || topics[0].SegmentRangeEnd != 5 {
		t.Errorf("topics[0] range = %d-%d, want 1-5", topics[0].SegmentRangeStart, topics[0].SegmentRangeEnd)
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

func TestActiveSession(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()

	now := float64(time.Now().Unix())

	rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, status, createdAt)
		VALUES ('sess-1', 'en_US', ?, 'active', ?)`, now, now)
	rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, endedAt, status, createdAt)
		VALUES ('sess-2', 'en_US', ?, ?, 'completed', ?)`, now-100, now-50, now-100)

	store := &Store{db: rawDB}

	sess, err := store.ActiveSession()
	if err != nil {
		t.Fatalf("ActiveSession: %v", err)
	}

	if sess == nil {
		t.Fatal("expected active session, got nil")
	}
	if sess.ID != "sess-1" {
		t.Errorf("session ID = %q, want %q", sess.ID, "sess-1")
	}
	if sess.Status != "active" {
		t.Errorf("status = %q, want %q", sess.Status, "active")
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
