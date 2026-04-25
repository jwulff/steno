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

	// LastDedupedSegmentSeq is the cursor advanced by the daemon's
	// DedupCoordinator. The migration backfills 0 for pre-existing rows.
	LastDedupedSegmentSeq int

	// PauseExpiresAt is the wall-clock expiry of a timed pause. Nil when
	// the session is not paused or the pause is indefinite.
	PauseExpiresAt *time.Time

	// PausedIndefinitely is true when pause has no auto-resume. Privacy-
	// critical: a corrupted/unmigrated row must not surprise-resume.
	PausedIndefinitely bool
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

	// DuplicateOf points at the canonical segment this row duplicates,
	// when the daemon's DedupCoordinator (U11) has marked it. Nil means
	// canonical / not yet evaluated. The default TUI/MCP query in U9
	// filters `WHERE duplicate_of IS NULL`.
	DuplicateOf *string

	// DedupMethod is one of "exact" | "normalized" | "fuzzy" when
	// DuplicateOf is set; nil otherwise.
	DedupMethod *string

	// HealMarker is a free-text annotation written when an in-place
	// pipeline restart preserves the session across a gap (e.g.
	// "after_gap:12s").
	HealMarker *string

	// MicPeakDB is the peak dBFS observed during this segment, used by
	// the daemon's audio-level heuristic for dedup. Nil for non-mic
	// segments and pre-migration rows.
	MicPeakDB *float64
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
