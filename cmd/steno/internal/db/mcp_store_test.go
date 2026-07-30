package db

import (
	"database/sql"
	"fmt"
	"slices"
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

// lagBase is a fixed epoch for the lagging-session fixture, chosen well
// clear of seedTestData's timestamps so the two can coexist in one DB.
const lagBase = 1720000000.0

// seedLaggingSession builds the shape of the 2026-07-29 incident: two
// source workers sharing one sequence counter, one of them behind. The
// sequence number is assigned when a result *finalizes*, so the row
// holding the highest sequence describes older audio than the row holding
// MAX(startedAt).
//
//	seq 1  microphone   T+10
//	seq 2  systemAudio  T+10
//	seq 3  microphone   T+40   ← mic worker keeping up
//	seq 4  systemAudio  T+20   ← sys worker behind; higher seq, older audio
//
// Chronological order is 1, 2, 4, 3. Sequence order is 1, 2, 3, 4.
func seedLaggingSession(t *testing.T, rawDB *sql.DB) {
	t.Helper()

	if _, err := rawDB.Exec(`INSERT INTO sessions (id, locale, startedAt, status, createdAt)
		VALUES ('sess-lag', 'en_US', ?, 'active', ?)`, lagBase, lagBase); err != nil {
		t.Fatalf("seed lagging session: %v", err)
	}

	rows := []struct {
		seq       int
		source    string
		audioAt   float64
		writtenAt float64
		text      string
	}{
		{1, "microphone", lagBase + 10, lagBase + 11, "First thing said."},
		{2, "systemAudio", lagBase + 10, lagBase + 12, "First thing heard."},
		{3, "microphone", lagBase + 40, lagBase + 41, "Third thing said."},
		{4, "systemAudio", lagBase + 20, lagBase + 90, "Second thing heard."},
	}
	for _, r := range rows {
		if _, err := rawDB.Exec(`INSERT INTO segments
			(id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt, source)
			VALUES (?, 'sess-lag', ?, ?, ?, ?, ?, ?)`,
			fmt.Sprintf("seg-lag-%d", r.seq), r.text,
			r.audioAt, r.audioAt+1, r.seq, r.writtenAt, r.source); err != nil {
			t.Fatalf("seed lagging segment %d: %v", r.seq, err)
		}
	}
}

// assertChronological fails if the segments are not in non-decreasing
// startedAt order, naming the first pair that regresses.
func assertChronological(t *testing.T, segments []Segment) {
	t.Helper()
	for i := 1; i < len(segments); i++ {
		if segments[i].StartedAt.Before(segments[i-1].StartedAt) {
			t.Fatalf("segments out of audio order at index %d: seq %d (%s) precedes seq %d (%s)",
				i,
				segments[i].SequenceNumber, segments[i].StartedAt.UTC(),
				segments[i-1].SequenceNumber, segments[i-1].StartedAt.UTC())
		}
	}
}

func TestSegmentsForSessionOrdersByAudioTime(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedLaggingSession(t, rawDB)

	store := NewStore(rawDB)
	segments, err := store.SegmentsForSession("sess-lag", 100, 0)
	if err != nil {
		t.Fatalf("SegmentsForSession: %v", err)
	}
	if len(segments) != 4 {
		t.Fatalf("got %d segments, want 4", len(segments))
	}
	assertChronological(t, segments)

	got := []int{}
	for _, s := range segments {
		got = append(got, s.SequenceNumber)
	}
	want := []int{1, 2, 4, 3}
	if !slices.Equal(got, want) {
		t.Errorf("sequence order = %v, want %v", got, want)
	}
}

func TestSegmentsForSessionPaginatesInAudioOrder(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedLaggingSession(t, rawDB)

	store := NewStore(rawDB)

	// A paginated read must slice the *chronological* sequence, not the
	// sequence-number one — otherwise page boundaries hide the lagging
	// row somewhere the caller never looks.
	page, err := store.SegmentsForSession("sess-lag", 2, 2)
	if err != nil {
		t.Fatalf("SegmentsForSession paginated: %v", err)
	}
	if len(page) != 2 {
		t.Fatalf("got %d segments, want 2", len(page))
	}
	if page[0].SequenceNumber != 4 || page[1].SequenceNumber != 3 {
		t.Errorf("page seqs = [%d %d], want [4 3]",
			page[0].SequenceNumber, page[1].SequenceNumber)
	}
}

func TestSegmentsForRangeOrdersByAudioTime(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedLaggingSession(t, rawDB)

	store := NewStore(rawDB)

	// The sequence-range filter is the API contract and stays; only the
	// ordering of what comes back changes.
	segments, err := store.SegmentsForRange("sess-lag", 2, 4)
	if err != nil {
		t.Fatalf("SegmentsForRange: %v", err)
	}
	if len(segments) != 3 {
		t.Fatalf("got %d segments, want 3", len(segments))
	}
	for _, s := range segments {
		if s.SequenceNumber < 2 || s.SequenceNumber > 4 {
			t.Errorf("seq %d outside requested range 2-4", s.SequenceNumber)
		}
	}
	assertChronological(t, segments)
}

func TestSegmentsForTimeRangeOrdersByAudioTime(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedLaggingSession(t, rawDB)

	store := NewStore(rawDB)
	segments, err := store.SegmentsForTimeRange("sess-lag", nil, nil)
	if err != nil {
		t.Fatalf("SegmentsForTimeRange: %v", err)
	}
	if len(segments) != 4 {
		t.Fatalf("got %d segments, want 4", len(segments))
	}
	assertChronological(t, segments)
}

func TestSessionLagOnLaggingSession(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedLaggingSession(t, rawDB)

	store := NewStore(rawDB)
	now := time.Unix(int64(lagBase+100), 0)

	lag, err := store.SessionLag("sess-lag", 5*time.Minute, now)
	if err != nil {
		t.Fatalf("SessionLag: %v", err)
	}
	if lag == nil {
		t.Fatal("expected lag for a session with segments")
	}

	// The row at MAX(sequenceNumber) is seq 4, describing audio at T+20.
	// The newest audio in the session is seq 3's, at T+40. A reader
	// ordering by sequence stops 20s short of what is already queryable.
	if got := lag.FrontierDivergence; got != 20*time.Second {
		t.Errorf("FrontierDivergence = %v, want 20s", got)
	}
	if got := lag.AudioTimeAtMaxSequence.Unix(); got != int64(lagBase+20) {
		t.Errorf("AudioTimeAtMaxSequence = %d, want %d", got, int64(lagBase+20))
	}
	if got := lag.MaxAudioTime.Unix(); got != int64(lagBase+40) {
		t.Errorf("MaxAudioTime = %d, want %d", got, int64(lagBase+40))
	}

	// Worst createdAt - startedAt among rows written in the window is
	// seq 4: audio at T+20, written at T+90.
	if got := lag.RecentIngestLag; got != 70*time.Second {
		t.Errorf("RecentIngestLag = %v, want 70s", got)
	}
	if lag.RecentSampleCount != 4 {
		t.Errorf("RecentSampleCount = %d, want 4", lag.RecentSampleCount)
	}
}

func TestSessionLagRecentWindowExcludesOlderWrites(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedLaggingSession(t, rawDB)

	store := NewStore(rawDB)
	now := time.Unix(int64(lagBase+100), 0)

	// A 20s window admits only seq 4 (written at T+90).
	lag, err := store.SessionLag("sess-lag", 20*time.Second, now)
	if err != nil {
		t.Fatalf("SessionLag: %v", err)
	}
	if lag == nil {
		t.Fatal("expected lag")
	}
	if lag.RecentSampleCount != 1 {
		t.Errorf("RecentSampleCount = %d, want 1", lag.RecentSampleCount)
	}
	if got := lag.RecentIngestLag; got != 70*time.Second {
		t.Errorf("RecentIngestLag = %v, want 70s", got)
	}

	// A window that admits nothing must not report a stale lag figure as
	// if it were current.
	quiet, err := store.SessionLag("sess-lag", time.Second, now)
	if err != nil {
		t.Fatalf("SessionLag quiet window: %v", err)
	}
	if quiet == nil {
		t.Fatal("expected lag")
	}
	if quiet.RecentSampleCount != 0 {
		t.Errorf("RecentSampleCount = %d, want 0", quiet.RecentSampleCount)
	}
	if quiet.RecentIngestLag != 0 {
		t.Errorf("RecentIngestLag = %v, want 0 when no rows sampled", quiet.RecentIngestLag)
	}
}

func TestSessionLagOnHealthySession(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)
	// seedTestData writes each segment at the instant its audio starts.
	now := time.Unix(1710000000+3600, 0)

	lag, err := store.SessionLag("sess-1", time.Hour, now)
	if err != nil {
		t.Fatalf("SessionLag: %v", err)
	}
	if lag == nil {
		t.Fatal("expected lag for a session with segments")
	}
	if lag.FrontierDivergence != 0 {
		t.Errorf("FrontierDivergence = %v, want 0 on a healthy session", lag.FrontierDivergence)
	}
	if lag.RecentIngestLag != 0 {
		t.Errorf("RecentIngestLag = %v, want 0 on a healthy session", lag.RecentIngestLag)
	}
}

func TestSessionLagNilForSessionWithoutSegments(t *testing.T) {
	rawDB := createTestDB(t)
	defer rawDB.Close()
	seedTestData(t, rawDB)

	store := NewStore(rawDB)
	now := time.Unix(1710000000+3600, 0)

	// sess-3 is seeded with no segments. "Empty" and "healthy" must be
	// distinguishable — a zero-valued lag would read as healthy.
	lag, err := store.SessionLag("sess-3", time.Hour, now)
	if err != nil {
		t.Fatalf("SessionLag: %v", err)
	}
	if lag != nil {
		t.Errorf("expected nil lag for a session with no segments, got %+v", lag)
	}

	missing, err := store.SessionLag("nope", time.Hour, now)
	if err != nil {
		t.Fatalf("SessionLag missing: %v", err)
	}
	if missing != nil {
		t.Errorf("expected nil lag for an unknown session, got %+v", missing)
	}
}
