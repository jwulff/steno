package db

import (
	"fmt"
	"os"
	"testing"
)

// TestLiveDatabase opens the real steno database and reads sessions/topics.
// Skipped if the database doesn't exist.
func TestLiveDatabase(t *testing.T) {
	dbPath := DefaultDBPath()
	if _, err := os.Stat(dbPath); os.IsNotExist(err) {
		t.Skip("database not found at", dbPath)
	}

	store, err := Open(dbPath)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer store.Close()

	// Read latest session
	sess, err := store.LatestSession()
	if err != nil {
		t.Fatalf("LatestSession: %v", err)
	}
	if sess == nil {
		fmt.Println("No sessions in database")
		return
	}

	fmt.Printf("Latest session: id=%s locale=%s status=%s started=%s\n",
		sess.ID, sess.Locale, sess.Status, sess.StartedAt.Format("2006-01-02 15:04:05"))

	// Read topics for the session
	topics, err := store.TopicsForSession(sess.ID)
	if err != nil {
		t.Fatalf("TopicsForSession: %v", err)
	}
	fmt.Printf("Topics for session: %d\n", len(topics))
	for i, topic := range topics {
		fmt.Printf("  %d. %s (segments %d-%d)\n", i+1, topic.Title,
			topic.SegmentRangeStart, topic.SegmentRangeEnd)
		if topic.Summary != "" {
			fmt.Printf("     %s\n", topic.Summary)
		}
	}

	// Check for active session
	active, err := store.ActiveSession()
	if err != nil {
		t.Fatalf("ActiveSession: %v", err)
	}
	if active != nil {
		fmt.Printf("Active session: id=%s\n", active.ID)
	} else {
		fmt.Println("No active session")
	}
}
