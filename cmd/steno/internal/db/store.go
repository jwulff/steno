package db

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// Store provides read-only access to the steno SQLite database.
type Store struct {
	db *sql.DB
}

// NewStore creates a Store from an existing *sql.DB (useful for tests).
func NewStore(db *sql.DB) *Store {
	return &Store{db: db}
}

// DefaultDBPath returns the default database path.
func DefaultDBPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "Steno", "steno.sqlite")
}

// Open opens the database in read-only mode with WAL.
func Open(path string) (*Store, error) {
	dsn := fmt.Sprintf("file:%s?mode=ro&_journal_mode=WAL", path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping database: %w", err)
	}
	return &Store{db: db}, nil
}

// Close closes the database connection.
func (s *Store) Close() error {
	return s.db.Close()
}

// GetOverview returns a high-level summary of the database.
func (s *Store) GetOverview() (*Overview, error) {
	overview := &Overview{}

	// Total session count
	row := s.db.QueryRow(`SELECT COUNT(*) FROM sessions`)
	if err := row.Scan(&overview.TotalSessions); err != nil {
		return nil, fmt.Errorf("count sessions: %w", err)
	}

	// Date range
	row = s.db.QueryRow(`SELECT MIN(startedAt), MAX(startedAt) FROM sessions`)
	var minTS, maxTS sql.NullFloat64
	if err := row.Scan(&minTS, &maxTS); err != nil {
		return nil, fmt.Errorf("date range: %w", err)
	}
	if minTS.Valid {
		t := timeFromUnix(minTS.Float64)
		overview.EarliestSession = &t
	}
	if maxTS.Valid {
		t := timeFromUnix(maxTS.Float64)
		overview.LatestSession = &t
	}

	// Active session
	active, err := s.ActiveSession()
	if err != nil {
		return nil, err
	}
	overview.ActiveSession = active

	// Recent sessions with counts (last 5)
	recentRows, err := s.db.Query(`
		SELECT id, locale, startedAt, endedAt, title, status, createdAt
		FROM sessions
		ORDER BY startedAt DESC
		LIMIT 5
	`)
	if err != nil {
		return nil, fmt.Errorf("recent sessions: %w", err)
	}
	var recentSessions []Session
	for recentRows.Next() {
		sess, err := scanSession(recentRows)
		if err != nil {
			recentRows.Close()
			return nil, err
		}
		recentSessions = append(recentSessions, sess)
	}
	recentRows.Close()
	if err := recentRows.Err(); err != nil {
		return nil, fmt.Errorf("iterate sessions: %w", err)
	}

	for _, sess := range recentSessions {
		counts, err := s.SessionCounts(sess.ID)
		if err != nil {
			return nil, err
		}
		overview.RecentSessions = append(overview.RecentSessions, SessionWithCounts{
			Session: sess,
			Counts:  counts,
		})
	}

	return overview, nil
}

// ListSessions returns sessions matching the given filters.
func (s *Store) ListSessions(limit int, before, after *time.Time, status string) ([]SessionWithCounts, error) {
	query := `SELECT id, locale, startedAt, endedAt, title, status, createdAt FROM sessions WHERE 1=1`
	var args []any

	if status != "" {
		query += ` AND status = ?`
		args = append(args, status)
	}
	if after != nil {
		query += ` AND startedAt >= ?`
		args = append(args, float64(after.Unix()))
	}
	if before != nil {
		query += ` AND startedAt <= ?`
		args = append(args, float64(before.Unix()))
	}

	query += ` ORDER BY startedAt DESC LIMIT ?`
	args = append(args, limit)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("list sessions: %w", err)
	}
	var sessions []Session
	for rows.Next() {
		sess, err := scanSession(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		sessions = append(sessions, sess)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	var results []SessionWithCounts
	for _, sess := range sessions {
		counts, err := s.SessionCounts(sess.ID)
		if err != nil {
			return nil, err
		}
		results = append(results, SessionWithCounts{Session: sess, Counts: counts})
	}
	return results, nil
}

// GetSession returns a single session by ID.
func (s *Store) GetSession(sessionID string) (*Session, error) {
	row := s.db.QueryRow(`
		SELECT id, locale, startedAt, endedAt, title, status, createdAt
		FROM sessions WHERE id = ?
	`, sessionID)

	var sess Session
	var startedAt, createdAt float64
	var endedAt sql.NullFloat64
	var title sql.NullString

	if err := row.Scan(&sess.ID, &sess.Locale, &startedAt, &endedAt,
		&title, &sess.Status, &createdAt); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("scan session: %w", err)
	}

	sess.StartedAt = timeFromUnix(startedAt)
	sess.CreatedAt = timeFromUnix(createdAt)
	if endedAt.Valid {
		t := timeFromUnix(endedAt.Float64)
		sess.EndedAt = &t
	}
	if title.Valid {
		sess.Title = title.String
	}

	return &sess, nil
}

// ActiveSession returns the most recent active session, if any.
func (s *Store) ActiveSession() (*Session, error) {
	row := s.db.QueryRow(`
		SELECT id, locale, startedAt, endedAt, title, status, createdAt
		FROM sessions
		WHERE status = 'active'
		ORDER BY startedAt DESC
		LIMIT 1
	`)

	var sess Session
	var startedAt, createdAt float64
	var endedAt sql.NullFloat64
	var title sql.NullString

	if err := row.Scan(&sess.ID, &sess.Locale, &startedAt, &endedAt,
		&title, &sess.Status, &createdAt); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("scan session: %w", err)
	}

	sess.StartedAt = timeFromUnix(startedAt)
	sess.CreatedAt = timeFromUnix(createdAt)
	if endedAt.Valid {
		t := timeFromUnix(endedAt.Float64)
		sess.EndedAt = &t
	}
	if title.Valid {
		sess.Title = title.String
	}

	return &sess, nil
}

// LatestSession returns the most recent session regardless of status.
func (s *Store) LatestSession() (*Session, error) {
	row := s.db.QueryRow(`
		SELECT id, locale, startedAt, endedAt, title, status, createdAt
		FROM sessions
		ORDER BY startedAt DESC
		LIMIT 1
	`)

	var sess Session
	var startedAt, createdAt float64
	var endedAt sql.NullFloat64
	var title sql.NullString

	if err := row.Scan(&sess.ID, &sess.Locale, &startedAt, &endedAt,
		&title, &sess.Status, &createdAt); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("scan session: %w", err)
	}

	sess.StartedAt = timeFromUnix(startedAt)
	sess.CreatedAt = timeFromUnix(createdAt)
	if endedAt.Valid {
		t := timeFromUnix(endedAt.Float64)
		sess.EndedAt = &t
	}
	if title.Valid {
		sess.Title = title.String
	}

	return &sess, nil
}

// TopicsForSession returns all topics for a session, ordered by segment range.
func (s *Store) TopicsForSession(sessionID string) ([]Topic, error) {
	rows, err := s.db.Query(`
		SELECT id, sessionId, title, summary, segmentRangeStart, segmentRangeEnd, createdAt
		FROM topics
		WHERE sessionId = ?
		ORDER BY segmentRangeStart ASC
	`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("query topics: %w", err)
	}
	defer rows.Close()

	var topics []Topic
	for rows.Next() {
		var t Topic
		var createdAt float64
		if err := rows.Scan(&t.ID, &t.SessionID, &t.Title, &t.Summary,
			&t.SegmentRangeStart, &t.SegmentRangeEnd, &createdAt); err != nil {
			return nil, fmt.Errorf("scan topic: %w", err)
		}
		t.CreatedAt = timeFromUnix(createdAt)
		topics = append(topics, t)
	}
	return topics, rows.Err()
}

// LatestSummary returns the most recent summary for a session.
func (s *Store) LatestSummary(sessionID string) (*Summary, error) {
	row := s.db.QueryRow(`
		SELECT id, sessionId, content, summaryType, segmentRangeStart, segmentRangeEnd, modelId, createdAt
		FROM summaries
		WHERE sessionId = ?
		ORDER BY createdAt DESC, rowid DESC
		LIMIT 1
	`, sessionID)

	var sum Summary
	var createdAt float64
	if err := row.Scan(&sum.ID, &sum.SessionID, &sum.Content, &sum.SummaryType,
		&sum.SegmentRangeStart, &sum.SegmentRangeEnd, &sum.ModelID, &createdAt); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("scan summary: %w", err)
	}
	sum.CreatedAt = timeFromUnix(createdAt)
	return &sum, nil
}

// SummariesForSession returns all summaries for a session.
func (s *Store) SummariesForSession(sessionID string) ([]Summary, error) {
	rows, err := s.db.Query(`
		SELECT id, sessionId, content, summaryType, segmentRangeStart, segmentRangeEnd, modelId, createdAt
		FROM summaries
		WHERE sessionId = ?
		ORDER BY createdAt ASC
	`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("query summaries: %w", err)
	}
	defer rows.Close()

	var summaries []Summary
	for rows.Next() {
		var sum Summary
		var createdAt float64
		if err := rows.Scan(&sum.ID, &sum.SessionID, &sum.Content, &sum.SummaryType,
			&sum.SegmentRangeStart, &sum.SegmentRangeEnd, &sum.ModelID, &createdAt); err != nil {
			return nil, fmt.Errorf("scan summary: %w", err)
		}
		sum.CreatedAt = timeFromUnix(createdAt)
		summaries = append(summaries, sum)
	}
	return summaries, rows.Err()
}

// SegmentsForSession returns paginated segments for a session, in audio
// order.
//
// Default-filter (U9): rows where `duplicate_of IS NOT NULL` are excluded
// — these are mic segments that the daemon's DedupCoordinator (U11)
// marked as duplicates of an overlapping system-audio segment. Raw access
// to all segments (including duplicates) is reserved for diagnostic SQL.
//
// Ordering (#81): `startedAt`, not `sequenceNumber`. The daemon assigns
// the sequence number when a recognizer result *finalizes*, from a counter
// shared by the mic and systemAudio workers, so sequence order is
// finalization order — not the order the audio happened. Whenever the two
// workers make unequal progress, ordering by sequence interleaves them
// wrongly. Matches `SQLiteTranscriptRepository.segments(for:)` on the
// daemon side, which already ordered this way.
func (s *Store) SegmentsForSession(sessionID string, limit, offset int) ([]Segment, error) {
	rows, err := s.db.Query(`
		SELECT id, sessionId, text, startedAt, endedAt, captured_at, confidence, sequenceNumber, createdAt, source, speaker_id
		FROM segments
		WHERE sessionId = ? AND duplicate_of IS NULL
		ORDER BY captured_at ASC, sequenceNumber ASC
		LIMIT ? OFFSET ?
	`, sessionID, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("query segments: %w", err)
	}
	defer rows.Close()
	return scanSegments(rows)
}

// SegmentsForRange returns segments within a sequence number range for a
// session, in audio order.
//
// Default-filter (U9): excludes `duplicate_of IS NOT NULL`.
//
// The sequence range stays the selection predicate — topics and summaries
// address segments by `segmentRangeStart`/`End`, so that is the contract —
// but the rows come back ordered by `startedAt` (#81).
func (s *Store) SegmentsForRange(sessionID string, start, end int) ([]Segment, error) {
	rows, err := s.db.Query(`
		SELECT id, sessionId, text, startedAt, endedAt, captured_at, confidence, sequenceNumber, createdAt, source, speaker_id
		FROM segments
		WHERE sessionId = ? AND sequenceNumber >= ? AND sequenceNumber <= ?
		  AND duplicate_of IS NULL
		ORDER BY captured_at ASC, sequenceNumber ASC
	`, sessionID, start, end)
	if err != nil {
		return nil, fmt.Errorf("query segments: %w", err)
	}
	defer rows.Close()
	return scanSegments(rows)
}

// SegmentsForTimeRange returns segments within a time window for a
// session, in audio order (#81).
//
// Default-filter (U9): excludes `duplicate_of IS NOT NULL`.
func (s *Store) SegmentsForTimeRange(sessionID string, after, before *time.Time) ([]Segment, error) {
	query := `SELECT id, sessionId, text, startedAt, endedAt, captured_at, confidence, sequenceNumber, createdAt, source, speaker_id
		FROM segments WHERE sessionId = ? AND duplicate_of IS NULL`
	args := []any{sessionID}

	if after != nil {
		query += ` AND captured_at >= ?`
		args = append(args, float64(after.Unix()))
	}
	if before != nil {
		query += ` AND captured_at <= ?`
		args = append(args, float64(before.Unix()))
	}

	query += ` ORDER BY captured_at ASC, sequenceNumber ASC`

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("query segments by time: %w", err)
	}
	defer rows.Close()
	return scanSegments(rows)
}

// SearchSegments searches segment text using LIKE.
//
// Default-filter (U9): excludes `duplicate_of IS NOT NULL`.
func (s *Store) SearchSegments(query, sessionID string, limit int) ([]Segment, error) {
	sqlQuery := `SELECT id, sessionId, text, startedAt, endedAt, captured_at, confidence, sequenceNumber, createdAt, source, speaker_id
		FROM segments WHERE text LIKE ? ESCAPE '\' AND duplicate_of IS NULL`
	args := []any{"%" + escapeLike(query) + "%"}

	if sessionID != "" {
		sqlQuery += ` AND sessionId = ?`
		args = append(args, sessionID)
	}

	// Newest-first means most recently *said*, not most recently
	// transcribed (#85).
	sqlQuery += ` ORDER BY captured_at DESC LIMIT ?`
	args = append(args, limit)

	rows, err := s.db.Query(sqlQuery, args...)
	if err != nil {
		return nil, fmt.Errorf("search segments: %w", err)
	}
	defer rows.Close()
	return scanSegments(rows)
}

// SearchTopics searches topic titles and summaries using LIKE.
func (s *Store) SearchTopics(query string, limit int) ([]Topic, error) {
	pattern := "%" + escapeLike(query) + "%"
	rows, err := s.db.Query(`
		SELECT id, sessionId, title, summary, segmentRangeStart, segmentRangeEnd, createdAt
		FROM topics
		WHERE title LIKE ? ESCAPE '\' OR summary LIKE ? ESCAPE '\'
		ORDER BY createdAt DESC
		LIMIT ?
	`, pattern, pattern, limit)
	if err != nil {
		return nil, fmt.Errorf("search topics: %w", err)
	}
	defer rows.Close()

	var topics []Topic
	for rows.Next() {
		var t Topic
		var createdAt float64
		if err := rows.Scan(&t.ID, &t.SessionID, &t.Title, &t.Summary,
			&t.SegmentRangeStart, &t.SegmentRangeEnd, &createdAt); err != nil {
			return nil, fmt.Errorf("scan topic: %w", err)
		}
		t.CreatedAt = timeFromUnix(createdAt)
		topics = append(topics, t)
	}
	return topics, rows.Err()
}

// SearchSummaries searches summary content using LIKE.
func (s *Store) SearchSummaries(query, sessionID string, limit int) ([]Summary, error) {
	sqlQuery := `SELECT id, sessionId, content, summaryType, segmentRangeStart, segmentRangeEnd, modelId, createdAt
		FROM summaries WHERE content LIKE ? ESCAPE '\'`
	args := []any{"%" + escapeLike(query) + "%"}

	if sessionID != "" {
		sqlQuery += ` AND sessionId = ?`
		args = append(args, sessionID)
	}

	sqlQuery += ` ORDER BY createdAt DESC LIMIT ?`
	args = append(args, limit)

	rows, err := s.db.Query(sqlQuery, args...)
	if err != nil {
		return nil, fmt.Errorf("search summaries: %w", err)
	}
	defer rows.Close()

	var summaries []Summary
	for rows.Next() {
		var sum Summary
		var createdAt float64
		if err := rows.Scan(&sum.ID, &sum.SessionID, &sum.Content, &sum.SummaryType,
			&sum.SegmentRangeStart, &sum.SegmentRangeEnd, &sum.ModelID, &createdAt); err != nil {
			return nil, fmt.Errorf("scan summary: %w", err)
		}
		sum.CreatedAt = timeFromUnix(createdAt)
		summaries = append(summaries, sum)
	}
	return summaries, rows.Err()
}

// SessionCounts returns segment, topic, and summary counts for a session.
//
// Default-filter (U9): segment count excludes `duplicate_of IS NOT NULL`
// rows, matching the default-filter applied by the segment readers.
func (s *Store) SessionCounts(sessionID string) (SessionCounts, error) {
	var c SessionCounts
	err := s.db.QueryRow(`SELECT COUNT(*) FROM segments WHERE sessionId = ? AND duplicate_of IS NULL`, sessionID).Scan(&c.Segments)
	if err != nil {
		return c, fmt.Errorf("count segments: %w", err)
	}
	err = s.db.QueryRow(`SELECT COUNT(*) FROM topics WHERE sessionId = ?`, sessionID).Scan(&c.Topics)
	if err != nil {
		return c, fmt.Errorf("count topics: %w", err)
	}
	err = s.db.QueryRow(`SELECT COUNT(*) FROM summaries WHERE sessionId = ?`, sessionID).Scan(&c.Summaries)
	if err != nil {
		return c, fmt.Errorf("count summaries: %w", err)
	}
	return c, nil
}

// DefaultLagWindow is the recent-writes window SessionLag samples for its
// ingest-lag figure. Wide enough to survive a natural pause in speech,
// narrow enough that the number describes now rather than the whole run.
const DefaultLagWindow = 5 * time.Minute

// SessionLag reports how far the write side has fallen behind for a
// session (#82). Returns nil — not a zero value — when the session has no
// segments, so "empty" stays distinguishable from "healthy".
//
// `window` bounds the recent-writes sample by `createdAt`; `now` is
// injected so the sample is deterministic in tests. Duplicate-marked rows
// are deliberately NOT filtered: lag is a property of the writer, and a
// row the dedup pass later discards still cost transcription time.
func (s *Store) SessionLag(sessionID string, window time.Duration, now time.Time) (*SessionLag, error) {
	// Both frontiers in one round trip. NULL for a session with no rows.
	var atMaxSeq, maxAudio sql.NullFloat64
	err := s.db.QueryRow(`
		SELECT
			(SELECT captured_at FROM segments WHERE sessionId = ?
			   ORDER BY sequenceNumber DESC LIMIT 1),
			(SELECT MAX(captured_at) FROM segments WHERE sessionId = ?)
	`, sessionID, sessionID).Scan(&atMaxSeq, &maxAudio)
	if err != nil {
		return nil, fmt.Errorf("query lag frontiers: %w", err)
	}
	if !atMaxSeq.Valid || !maxAudio.Valid {
		return nil, nil
	}

	lag := &SessionLag{
		AudioTimeAtMaxSequence: timeFromUnix(atMaxSeq.Float64),
		MaxAudioTime:           timeFromUnix(maxAudio.Float64),
	}
	// MAX(startedAt) is by definition >= any single row's startedAt, so
	// this cannot go negative.
	lag.FrontierDivergence = lag.MaxAudioTime.Sub(lag.AudioTimeAtMaxSequence)

	cutoff := float64(now.Add(-window).Unix())
	var count int
	var worst sql.NullFloat64
	err = s.db.QueryRow(`
		SELECT COUNT(*), MAX(createdAt - captured_at)
		FROM segments
		WHERE sessionId = ? AND createdAt >= ?
	`, sessionID, cutoff).Scan(&count, &worst)
	if err != nil {
		return nil, fmt.Errorf("query recent ingest lag: %w", err)
	}
	lag.RecentSampleCount = count
	if count > 0 && worst.Valid && worst.Float64 > 0 {
		// A negative gap would mean the row was committed before the
		// audio it describes — clock skew, not lag. Report nothing.
		lag.RecentIngestLag = time.Duration(worst.Float64 * float64(time.Second))
	}

	return lag, nil
}

// scanSession scans a session row from a *sql.Rows.
func scanSession(rows *sql.Rows) (Session, error) {
	var sess Session
	var startedAt, createdAt float64
	var endedAt sql.NullFloat64
	var title sql.NullString

	if err := rows.Scan(&sess.ID, &sess.Locale, &startedAt, &endedAt,
		&title, &sess.Status, &createdAt); err != nil {
		return sess, fmt.Errorf("scan session: %w", err)
	}

	sess.StartedAt = timeFromUnix(startedAt)
	sess.CreatedAt = timeFromUnix(createdAt)
	if endedAt.Valid {
		t := timeFromUnix(endedAt.Float64)
		sess.EndedAt = &t
	}
	if title.Valid {
		sess.Title = title.String
	}

	return sess, nil
}

// scanSegments scans all segment rows.
//
// The SELECT list must match: id, sessionId, text, startedAt, endedAt,
// confidence, sequenceNumber, createdAt, source, speaker_id.
//
// speaker_id arrived via the diarization track — it is NULL on rows that
// predate the pipeline and on segments the daemon hasn't yet folded into
// a cluster, so we scan into a NullString and only assign the field
// when present (matches the confidence pattern above).
func scanSegments(rows *sql.Rows) ([]Segment, error) {
	var segments []Segment
	for rows.Next() {
		var seg Segment
		var startedAt, endedAt, createdAt float64
		var capturedAt sql.NullFloat64
		var confidence sql.NullFloat64
		var speakerID sql.NullString
		if err := rows.Scan(&seg.ID, &seg.SessionID, &seg.Text,
			&startedAt, &endedAt, &capturedAt, &confidence, &seg.SequenceNumber, &createdAt, &seg.Source, &speakerID); err != nil {
			return nil, fmt.Errorf("scan segment: %w", err)
		}
		seg.StartedAt = timeFromUnix(startedAt)
		seg.EndedAt = timeFromUnix(endedAt)
		// The migration backfills captured_at and the daemon always writes
		// it, so NULL means a row this reader didn't produce. Fall back to
		// the emission timestamp rather than failing the whole query — a
		// read-only consumer should degrade, not refuse to open a session.
		if capturedAt.Valid {
			seg.CapturedAt = timeFromUnix(capturedAt.Float64)
		} else {
			seg.CapturedAt = seg.StartedAt
		}
		seg.CreatedAt = timeFromUnix(createdAt)
		if confidence.Valid {
			c := confidence.Float64
			seg.Confidence = &c
		}
		if speakerID.Valid {
			seg.SpeakerID = speakerID.String
		}
		segments = append(segments, seg)
	}
	return segments, rows.Err()
}

func timeFromUnix(ts float64) time.Time {
	sec := int64(ts)
	nsec := int64((ts - float64(sec)) * 1e9)
	return time.Unix(sec, nsec)
}

// escapeLike escapes SQL LIKE special characters using backslash as escape char.
// All LIKE queries using this must include ESCAPE '\' clause.
func escapeLike(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, "%", `\%`)
	s = strings.ReplaceAll(s, "_", `\_`)
	return s
}
