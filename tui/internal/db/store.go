package db

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

// Store provides read-only access to the steno SQLite database.
type Store struct {
	db *sql.DB
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

	// Verify connection
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

func timeFromUnix(ts float64) time.Time {
	sec := int64(ts)
	nsec := int64((ts - float64(sec)) * 1e9)
	return time.Unix(sec, nsec)
}
