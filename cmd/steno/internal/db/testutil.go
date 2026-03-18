package db

import (
	"database/sql"
	"fmt"
	"testing"

	_ "modernc.org/sqlite"
)

// createTestDB creates an in-memory SQLite database with the steno schema.
func createTestDB(t *testing.T) *sql.DB {
	t.Helper()

	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	// Ensure single connection so all operations share the same in-memory DB.
	db.SetMaxOpenConns(1)

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

// seedTestData populates the test database with a realistic dataset.
func seedTestData(t *testing.T, rawDB *sql.DB) {
	t.Helper()

	// Session 1: completed, 1 hour ago, with segments, topics, and summaries
	s1Start := 1710000000.0 // fixed timestamps for deterministic tests
	s1End := s1Start + 3600
	rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, endedAt, title, status, createdAt)
		VALUES ('sess-1', 'en_US', ?, ?, 'Team Standup', 'completed', ?)`, s1Start, s1End, s1Start)

	for i := 1; i <= 10; i++ {
		conf := 0.9 + float64(i)*0.01
		rawDB.Exec(`INSERT INTO segments (id, sessionId, text, startedAt, endedAt, confidence, sequenceNumber, createdAt, source)
			VALUES (?, 'sess-1', ?, ?, ?, ?, ?, ?, 'microphone')`,
			fmt.Sprintf("seg-1-%d", i),
			fmt.Sprintf("Segment %d from session one.", i),
			s1Start+float64(i)*10,
			s1Start+float64(i)*10+9,
			conf, i,
			s1Start+float64(i)*10)
	}

	rawDB.Exec(`INSERT INTO topics (id, sessionId, title, summary, segmentRangeStart, segmentRangeEnd, createdAt)
		VALUES ('top-1', 'sess-1', 'Sprint Planning', 'Discussion about next sprint goals', 1, 5, ?)`, s1Start+100)
	rawDB.Exec(`INSERT INTO topics (id, sessionId, title, summary, segmentRangeStart, segmentRangeEnd, createdAt)
		VALUES ('top-2', 'sess-1', 'Code Review', 'Reviewing the auth module', 6, 10, ?)`, s1Start+200)

	rawDB.Exec(`INSERT INTO summaries (id, sessionId, content, summaryType, segmentRangeStart, segmentRangeEnd, modelId, createdAt)
		VALUES ('sum-1', 'sess-1', 'Team discussed sprint goals and reviewed auth module.', 'rolling', 1, 10, 'local-llm', ?)`, s1Start+300)

	// Session 2: active, started recently
	s2Start := s1Start + 7200
	rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, status, createdAt)
		VALUES ('sess-2', 'en_US', ?, 'active', ?)`, s2Start, s2Start)

	for i := 1; i <= 3; i++ {
		rawDB.Exec(`INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt, source)
			VALUES (?, 'sess-2', ?, ?, ?, ?, ?, 'systemAudio')`,
			fmt.Sprintf("seg-2-%d", i),
			fmt.Sprintf("Active session segment %d.", i),
			s2Start+float64(i)*10,
			s2Start+float64(i)*10+9,
			i, s2Start+float64(i)*10)
	}

	rawDB.Exec(`INSERT INTO topics (id, sessionId, title, summary, segmentRangeStart, segmentRangeEnd, createdAt)
		VALUES ('top-3', 'sess-2', 'Architecture Discussion', 'Talking about MCP server design', 1, 3, ?)`, s2Start+100)

	// Session 3: interrupted, oldest
	s3Start := s1Start - 86400
	s3End := s3Start + 600
	rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, endedAt, status, createdAt)
		VALUES ('sess-3', 'en_US', ?, ?, 'interrupted', ?)`, s3Start, s3End, s3Start)
}
