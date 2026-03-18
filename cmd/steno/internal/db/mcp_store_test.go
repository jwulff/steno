package db

import (
	"testing"
	"time"
)

func TestGetOverview(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)
	overview, err := store.GetOverview()
	if err != nil {
		t.Fatalf("GetOverview: %v", err)
	}

	if overview.TotalSessions != 3 {
		t.Errorf("TotalSessions = %d, want 3", overview.TotalSessions)
	}
	if overview.ActiveSession == nil {
		t.Fatal("expected active session")
	}
	if overview.ActiveSession.ID != "sess-2" {
		t.Errorf("active session ID = %q, want sess-2", overview.ActiveSession.ID)
	}
	if len(overview.RecentSessions) != 3 {
		t.Errorf("RecentSessions = %d, want 3", len(overview.RecentSessions))
	}
	if overview.EarliestSession == nil || overview.LatestSession == nil {
		t.Fatal("expected date range")
	}
}

func TestGetOverviewEmpty(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()

	store := NewStore(rawDB)
	overview, err := store.GetOverview()
	if err != nil {
		t.Fatalf("GetOverview: %v", err)
	}

	if overview.TotalSessions != 0 {
		t.Errorf("TotalSessions = %d, want 0", overview.TotalSessions)
	}
	if overview.ActiveSession != nil {
		t.Errorf("expected no active session")
	}
}

func TestListSessions(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)

	// All sessions
	sessions, err := store.ListSessions(10, nil, nil, "")
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions) != 3 {
		t.Fatalf("got %d sessions, want 3", len(sessions))
	}
	// Should be ordered by startedAt DESC
	if sessions[0].Session.ID != "sess-2" {
		t.Errorf("first session = %q, want sess-2", sessions[0].Session.ID)
	}

	// Filter by status
	completed, err := store.ListSessions(10, nil, nil, "completed")
	if err != nil {
		t.Fatalf("ListSessions completed: %v", err)
	}
	if len(completed) != 1 {
		t.Fatalf("got %d completed, want 1", len(completed))
	}
	if completed[0].Session.ID != "sess-1" {
		t.Errorf("completed session = %q, want sess-1", completed[0].Session.ID)
	}

	// Filter by limit
	limited, err := store.ListSessions(1, nil, nil, "")
	if err != nil {
		t.Fatalf("ListSessions limited: %v", err)
	}
	if len(limited) != 1 {
		t.Errorf("got %d, want 1", len(limited))
	}

	// Counts are populated
	if sessions[0].Counts.Segments != 3 {
		t.Errorf("sess-2 segments = %d, want 3", sessions[0].Counts.Segments)
	}
	if sessions[0].Counts.Topics != 1 {
		t.Errorf("sess-2 topics = %d, want 1", sessions[0].Counts.Topics)
	}
}

func TestListSessionsTimeFilters(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)

	// After filter — should exclude sess-3 (oldest)
	after := time.Unix(1710000000-1, 0)
	sessions, err := store.ListSessions(10, nil, &after, "")
	if err != nil {
		t.Fatalf("ListSessions after: %v", err)
	}
	if len(sessions) != 2 {
		t.Fatalf("got %d sessions after filter, want 2", len(sessions))
	}

	// Before filter — should exclude sess-2 (newest)
	before := time.Unix(1710000000+1, 0)
	sessions, err = store.ListSessions(10, &before, nil, "")
	if err != nil {
		t.Fatalf("ListSessions before: %v", err)
	}
	if len(sessions) != 2 {
		t.Fatalf("got %d sessions before filter, want 2", len(sessions))
	}
}

func TestGetSession(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)

	sess, err := store.GetSession("sess-1")
	if err != nil {
		t.Fatalf("GetSession: %v", err)
	}
	if sess == nil {
		t.Fatal("expected session, got nil")
	}
	if sess.Title != "Team Standup" {
		t.Errorf("Title = %q, want %q", sess.Title, "Team Standup")
	}
	if sess.Status != "completed" {
		t.Errorf("Status = %q, want completed", sess.Status)
	}
	if sess.EndedAt == nil {
		t.Error("expected EndedAt to be set")
	}
}

func TestGetSessionNotFound(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()

	store := NewStore(rawDB)
	sess, err := store.GetSession("nonexistent")
	if err != nil {
		t.Fatalf("GetSession: %v", err)
	}
	if sess != nil {
		t.Errorf("expected nil, got %q", sess.ID)
	}
}

func TestSegmentsForSession(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)

	// All segments
	segments, err := store.SegmentsForSession("sess-1", 100, 0)
	if err != nil {
		t.Fatalf("SegmentsForSession: %v", err)
	}
	if len(segments) != 10 {
		t.Fatalf("got %d segments, want 10", len(segments))
	}

	// Pagination
	page, err := store.SegmentsForSession("sess-1", 3, 0)
	if err != nil {
		t.Fatalf("SegmentsForSession paginated: %v", err)
	}
	if len(page) != 3 {
		t.Fatalf("got %d segments, want 3", len(page))
	}
	if page[0].SequenceNumber != 1 {
		t.Errorf("first seq = %d, want 1", page[0].SequenceNumber)
	}

	// Offset
	page2, err := store.SegmentsForSession("sess-1", 3, 3)
	if err != nil {
		t.Fatalf("SegmentsForSession offset: %v", err)
	}
	if len(page2) != 3 {
		t.Fatalf("got %d segments, want 3", len(page2))
	}
	if page2[0].SequenceNumber != 4 {
		t.Errorf("first seq = %d, want 4", page2[0].SequenceNumber)
	}
}

func TestSegmentsForTimeRange(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)

	// Time range that covers segments 3-5 of sess-1
	after := time.Unix(1710000030, 0)
	before := time.Unix(1710000059, 0)
	segments, err := store.SegmentsForTimeRange("sess-1", &after, &before)
	if err != nil {
		t.Fatalf("SegmentsForTimeRange: %v", err)
	}
	if len(segments) != 3 {
		t.Fatalf("got %d segments, want 3", len(segments))
	}
}

func TestSearchSegments(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)

	// Search across all sessions
	results, err := store.SearchSegments("session one", "", 100)
	if err != nil {
		t.Fatalf("SearchSegments: %v", err)
	}
	if len(results) != 10 {
		t.Errorf("got %d results, want 10", len(results))
	}

	// Search scoped to session
	results, err = store.SearchSegments("segment", "sess-2", 100)
	if err != nil {
		t.Fatalf("SearchSegments scoped: %v", err)
	}
	if len(results) != 3 {
		t.Errorf("got %d results, want 3", len(results))
	}

	// Limit
	results, err = store.SearchSegments("Segment", "", 2)
	if err != nil {
		t.Fatalf("SearchSegments limited: %v", err)
	}
	if len(results) != 2 {
		t.Errorf("got %d results, want 2", len(results))
	}
}

func TestSearchTopics(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)

	// Search by title
	results, err := store.SearchTopics("Sprint", 10)
	if err != nil {
		t.Fatalf("SearchTopics: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("got %d results, want 1", len(results))
	}
	if results[0].Title != "Sprint Planning" {
		t.Errorf("Title = %q, want Sprint Planning", results[0].Title)
	}

	// Search by summary
	results, err = store.SearchTopics("auth module", 10)
	if err != nil {
		t.Fatalf("SearchTopics summary: %v", err)
	}
	if len(results) != 1 {
		t.Errorf("got %d results, want 1", len(results))
	}
}

func TestSearchSummaries(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)

	results, err := store.SearchSummaries("sprint goals", "", 10)
	if err != nil {
		t.Fatalf("SearchSummaries: %v", err)
	}
	if len(results) != 1 {
		t.Errorf("got %d results, want 1", len(results))
	}
}

func TestSummariesForSession(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)

	summaries, err := store.SummariesForSession("sess-1")
	if err != nil {
		t.Fatalf("SummariesForSession: %v", err)
	}
	if len(summaries) != 1 {
		t.Fatalf("got %d summaries, want 1", len(summaries))
	}
	if summaries[0].Content != "Team discussed sprint goals and reviewed auth module." {
		t.Errorf("unexpected content: %q", summaries[0].Content)
	}
}

func TestSessionCounts(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)

	counts, err := store.SessionCounts("sess-1")
	if err != nil {
		t.Fatalf("SessionCounts: %v", err)
	}
	if counts.Segments != 10 {
		t.Errorf("Segments = %d, want 10", counts.Segments)
	}
	if counts.Topics != 2 {
		t.Errorf("Topics = %d, want 2", counts.Topics)
	}
	if counts.Summaries != 1 {
		t.Errorf("Summaries = %d, want 1", counts.Summaries)
	}
}

func TestTopicsForSession(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)

	topics, err := store.TopicsForSession("sess-1")
	if err != nil {
		t.Fatalf("TopicsForSession: %v", err)
	}
	if len(topics) != 2 {
		t.Fatalf("got %d topics, want 2", len(topics))
	}
	if topics[0].Title != "Sprint Planning" {
		t.Errorf("first topic = %q, want Sprint Planning", topics[0].Title)
	}
}

func TestActiveSession(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)

	sess, err := store.ActiveSession()
	if err != nil {
		t.Fatalf("ActiveSession: %v", err)
	}
	if sess == nil {
		t.Fatal("expected active session")
	}
	if sess.ID != "sess-2" {
		t.Errorf("ID = %q, want sess-2", sess.ID)
	}
}
