// Package db provides read-only SQLite access to the steno database.
package db

import "time"

// Session represents a recording session.
type Session struct {
	ID        string
	Locale    string
	StartedAt time.Time
	EndedAt   *time.Time
	Title     string
	Status    string
	CreatedAt time.Time
}

// Segment represents a finalized transcript segment.
type Segment struct {
	ID             string
	SessionID      string
	Text           string
	StartedAt      time.Time
	EndedAt        time.Time
	Confidence     *float64
	SequenceNumber int
	CreatedAt      time.Time
	Source         string
}

// Topic represents an extracted topic.
type Topic struct {
	ID                string
	SessionID         string
	Title             string
	Summary           string
	SegmentRangeStart int
	SegmentRangeEnd   int
	CreatedAt         time.Time
}

// Summary represents an LLM-generated summary.
type Summary struct {
	ID                string
	SessionID         string
	Content           string
	SummaryType       string
	SegmentRangeStart int
	SegmentRangeEnd   int
	ModelID           string
	CreatedAt         time.Time
}

// SessionCounts holds aggregate counts for a session.
type SessionCounts struct {
	Segments  int
	Topics    int
	Summaries int
}

// Overview holds high-level database summary info.
type Overview struct {
	TotalSessions  int
	ActiveSession  *Session
	RecentSessions []SessionWithCounts
	EarliestSession *time.Time
	LatestSession   *time.Time
}

// SessionWithCounts pairs a session with its aggregate counts.
type SessionWithCounts struct {
	Session Session
	Counts  SessionCounts
}
