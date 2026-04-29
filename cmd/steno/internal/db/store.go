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

// SegmentsForSession returns paginated segments for a session.
//
// Default-filter (U9): rows where `duplicate_of IS NOT NULL` are excluded
// — these are mic segments that the daemon's DedupCoordinator (U11)
// marked as duplicates of an overlapping system-audio segment. Raw access
// to all segments (including duplicates) is reserved for diagnostic SQL.
func (s *Store) SegmentsForSession(sessionID string, limit, offset int) ([]Segment, error) {
	rows, err := s.db.Query(`
		SELECT id, sessionId, text, startedAt, endedAt, confidence, sequenceNumber, createdAt, source
		FROM segments
		WHERE sessionId = ? AND duplicate_of IS NULL
		ORDER BY sequenceNumber ASC
		LIMIT ? OFFSET ?
	`, sessionID, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("query segments: %w", err)
	}
	defer rows.Close()
	return scanSegments(rows)
}

// SegmentsForRange returns segments within a sequence number range for a session.
//
// Default-filter (U9): excludes `duplicate_of IS NOT NULL`.
func (s *Store) SegmentsForRange(sessionID string, start, end int) ([]Segment, error) {
	rows, err := s.db.Query(`
		SELECT id, sessionId, text, startedAt, endedAt, confidence, sequenceNumber, createdAt, source
		FROM segments
		WHERE sessionId = ? AND sequenceNumber >= ? AND sequenceNumber <= ?
		  AND duplicate_of IS NULL
		ORDER BY sequenceNumber ASC
	`, sessionID, start, end)
	if err != nil {
		return nil, fmt.Errorf("query segments: %w", err)
	}
	defer rows.Close()
	return scanSegments(rows)
}

// SegmentsForTimeRange returns segments within a time window for a session.
//
// Default-filter (U9): excludes `duplicate_of IS NOT NULL`.
func (s *Store) SegmentsForTimeRange(sessionID string, after, before *time.Time) ([]Segment, error) {
	query := `SELECT id, sessionId, text, startedAt, endedAt, confidence, sequenceNumber, createdAt, source
		FROM segments WHERE sessionId = ? AND duplicate_of IS NULL`
	args := []any{sessionID}

	if after != nil {
		query += ` AND startedAt >= ?`
		args = append(args, float64(after.Unix()))
	}
	if before != nil {
		query += ` AND startedAt <= ?`
		args = append(args, float64(before.Unix()))
	}

	query += ` ORDER BY sequenceNumber ASC`

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
	sqlQuery := `SELECT id, sessionId, text, startedAt, endedAt, confidence, sequenceNumber, createdAt, source
		FROM segments WHERE text LIKE ? ESCAPE '\' AND duplicate_of IS NULL`
	args := []any{"%" + escapeLike(query) + "%"}

	if sessionID != "" {
		sqlQuery += ` AND sessionId = ?`
		args = append(args, sessionID)
	}

	sqlQuery += ` ORDER BY startedAt DESC LIMIT ?`
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
func scanSegments(rows *sql.Rows) ([]Segment, error) {
	var segments []Segment
	for rows.Next() {
		var seg Segment
		var startedAt, endedAt, createdAt float64
		var confidence sql.NullFloat64
		if err := rows.Scan(&seg.ID, &seg.SessionID, &seg.Text,
			&startedAt, &endedAt, &confidence, &seg.SequenceNumber, &createdAt, &seg.Source); err != nil {
			return nil, fmt.Errorf("scan segment: %w", err)
		}
		seg.StartedAt = timeFromUnix(startedAt)
		seg.EndedAt = timeFromUnix(endedAt)
		seg.CreatedAt = timeFromUnix(createdAt)
		if confidence.Valid {
			c := confidence.Float64
			seg.Confidence = &c
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
