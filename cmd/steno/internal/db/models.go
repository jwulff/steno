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

	// SpeakerID is the diarization UUID assigned to this segment by the
	// daemon's speaker-clustering pipeline. Empty when the segment was
	// recorded before diarization shipped, when the segment is too short
	// to cluster, or when speaker assignment has not yet been backfilled
	// by the daemon's `updateSpeaker` repository writer. The TUI maps
	// the UUID to a per-session "Speaker N" label via first-seen order.
	SpeakerID string
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

// SessionLag describes how far the daemon's write side has fallen behind
// the audio it is transcribing (#82).
//
// Two independent measures, because they answer different questions:
//
//   - FrontierDivergence answers "is sequence order safe to read?" It is
//     the gap between the newest audio in the session and the audio
//     described by the highest-numbered row. Nonzero means a consumer
//     ordering or cursoring by sequenceNumber is looking at a frontier
//     that trails what is already queryable by timestamp — the sequence
//     counter is shared by the mic and systemAudio workers, so it drifts
//     whenever they make unequal progress.
//   - RecentIngestLag answers "how far behind wall clock is the writer
//     right now?" It is the worst gap between a row's audio time and the
//     moment it was committed, over rows written in the recent window.
//     This is the actionable one: a live consumer seeing tens of minutes
//     here should treat a silent transcript as backlog, not as quiet.
type SessionLag struct {
	// AudioTimeAtMaxSequence is the audio time of the row holding the
	// session's highest sequence number — where a sequence-ordered
	// reader's tail sits.
	AudioTimeAtMaxSequence time.Time

	// MaxAudioTime is the newest audio time in the session — where a
	// timestamp-ordered reader's tail sits.
	MaxAudioTime time.Time

	// FrontierDivergence is MaxAudioTime - AudioTimeAtMaxSequence. Zero
	// on a healthy session.
	FrontierDivergence time.Duration

	// RecentIngestLag is the worst commit-minus-audio gap among rows
	// written inside the sampled window. Zero when RecentSampleCount is
	// zero — absence of recent writes is not evidence of health.
	RecentIngestLag time.Duration

	// RecentSampleCount is how many rows the window covered. Zero means
	// nothing was written recently, so RecentIngestLag says nothing.
	RecentSampleCount int
}

// Overview holds high-level database summary info.
type Overview struct {
	TotalSessions   int
	ActiveSession   *Session
	RecentSessions  []SessionWithCounts
	EarliestSession *time.Time
	LatestSession   *time.Time
}

// SessionWithCounts pairs a session with its aggregate counts.
type SessionWithCounts struct {
	Session Session
	Counts  SessionCounts
}
