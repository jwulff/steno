package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/jwulff/steno/mcp/internal/db"
	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
	_ "modernc.org/sqlite"
)

// testServer creates an MCP server backed by a seeded in-memory database.
func testServer(t *testing.T) *server.MCPServer {
	t.Helper()

	rawDB := createTestDB(t)
	seedTestData(t, rawDB)
	t.Cleanup(func() { rawDB.Close() })

	store := db.NewStore(rawDB)
	s := server.NewMCPServer("steno-mcp-test", "0.0.1", server.WithToolCapabilities(false))
	RegisterTools(s, store)
	return s
}

// callTool invokes a tool by name on the server and returns the text result.
func callTool(t *testing.T, s *server.MCPServer, name string, args map[string]any) string {
	t.Helper()

	req := mcp.CallToolRequest{}
	req.Params.Name = name
	req.Params.Arguments = args

	result := s.HandleMessage(context.Background(), mustMarshal(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "tools/call",
		"params":  req.Params,
	}))

	data, err := json.Marshal(result)
	if err != nil {
		t.Fatalf("marshal result: %v", err)
	}

	var resp struct {
		Result struct {
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
			IsError bool `json:"isError"`
		} `json:"result"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		t.Fatalf("unmarshal response: %v\nraw: %s", err, string(data))
	}

	if len(resp.Result.Content) == 0 {
		t.Fatalf("no content in response for %s: %s", name, string(data))
	}

	return resp.Result.Content[0].Text
}

func mustMarshal(t *testing.T, v any) json.RawMessage {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return data
}

// --- Schema + seed (duplicated from db package since it's not exported) ---

func createTestDB(t *testing.T) *sql.DB {
	t.Helper()
	d, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	d.SetMaxOpenConns(1)
	schema := `
		CREATE TABLE sessions (id TEXT PRIMARY KEY, locale TEXT NOT NULL, startedAt REAL NOT NULL, endedAt REAL, title TEXT, status TEXT NOT NULL DEFAULT 'active', createdAt REAL NOT NULL);
		CREATE TABLE segments (id TEXT PRIMARY KEY, sessionId TEXT NOT NULL REFERENCES sessions(id), text TEXT NOT NULL, startedAt REAL NOT NULL, endedAt REAL NOT NULL, confidence REAL, sequenceNumber INTEGER NOT NULL, createdAt REAL NOT NULL, source TEXT NOT NULL DEFAULT 'microphone', UNIQUE(sessionId, sequenceNumber));
		CREATE TABLE topics (id TEXT PRIMARY KEY, sessionId TEXT NOT NULL REFERENCES sessions(id), title TEXT NOT NULL, summary TEXT NOT NULL, segmentRangeStart INTEGER NOT NULL, segmentRangeEnd INTEGER NOT NULL, createdAt REAL NOT NULL);
		CREATE TABLE summaries (id TEXT PRIMARY KEY, sessionId TEXT NOT NULL REFERENCES sessions(id), content TEXT NOT NULL, summaryType TEXT NOT NULL, segmentRangeStart INTEGER NOT NULL, segmentRangeEnd INTEGER NOT NULL, modelId TEXT NOT NULL, createdAt REAL NOT NULL);
	`
	if _, err := d.Exec(schema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	return d
}

func seedTestData(t *testing.T, d *sql.DB) {
	t.Helper()
	s1Start := 1710000000.0
	s1End := s1Start + 3600
	d.Exec(`INSERT INTO sessions (id, locale, startedAt, endedAt, title, status, createdAt) VALUES ('sess-1', 'en_US', ?, ?, 'Team Standup', 'completed', ?)`, s1Start, s1End, s1Start)
	for i := 1; i <= 10; i++ {
		d.Exec(`INSERT INTO segments (id, sessionId, text, startedAt, endedAt, confidence, sequenceNumber, createdAt, source) VALUES (?, 'sess-1', ?, ?, ?, ?, ?, ?, 'microphone')`,
			fmt.Sprintf("seg-1-%d", i), fmt.Sprintf("Segment %d from session one.", i),
			s1Start+float64(i)*10, s1Start+float64(i)*10+9, 0.9+float64(i)*0.01, i, s1Start+float64(i)*10)
	}
	d.Exec(`INSERT INTO topics (id, sessionId, title, summary, segmentRangeStart, segmentRangeEnd, createdAt) VALUES ('top-1', 'sess-1', 'Sprint Planning', 'Discussion about next sprint goals', 1, 5, ?)`, s1Start+100)
	d.Exec(`INSERT INTO topics (id, sessionId, title, summary, segmentRangeStart, segmentRangeEnd, createdAt) VALUES ('top-2', 'sess-1', 'Code Review', 'Reviewing the auth module', 6, 10, ?)`, s1Start+200)
	d.Exec(`INSERT INTO summaries (id, sessionId, content, summaryType, segmentRangeStart, segmentRangeEnd, modelId, createdAt) VALUES ('sum-1', 'sess-1', 'Team discussed sprint goals and reviewed auth module.', 'rolling', 1, 10, 'local-llm', ?)`, s1Start+300)

	s2Start := s1Start + 7200
	d.Exec(`INSERT INTO sessions (id, locale, startedAt, status, createdAt) VALUES ('sess-2', 'en_US', ?, 'active', ?)`, s2Start, s2Start)
	for i := 1; i <= 3; i++ {
		d.Exec(`INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt, source) VALUES (?, 'sess-2', ?, ?, ?, ?, ?, 'systemAudio')`,
			fmt.Sprintf("seg-2-%d", i), fmt.Sprintf("Active session segment %d.", i),
			s2Start+float64(i)*10, s2Start+float64(i)*10+9, i, s2Start+float64(i)*10)
	}
	d.Exec(`INSERT INTO topics (id, sessionId, title, summary, segmentRangeStart, segmentRangeEnd, createdAt) VALUES ('top-3', 'sess-2', 'Architecture Discussion', 'Talking about MCP server design', 1, 3, ?)`, s2Start+100)

	s3Start := s1Start - 86400
	s3End := s3Start + 600
	d.Exec(`INSERT INTO sessions (id, locale, startedAt, endedAt, status, createdAt) VALUES ('sess-3', 'en_US', ?, ?, 'interrupted', ?)`, s3Start, s3End, s3Start)
}

// --- Tests ---

func TestGetOverviewTool(t *testing.T) {
	s := testServer(t)
	text := callTool(t, s, "get_overview", nil)

	var resp overviewResponse
	if err := json.Unmarshal([]byte(text), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if resp.TotalSessions != 3 {
		t.Errorf("TotalSessions = %d, want 3", resp.TotalSessions)
	}
	if resp.ActiveSession == nil {
		t.Error("expected active session")
	}
	if len(resp.RecentSessions) != 3 {
		t.Errorf("RecentSessions = %d, want 3", len(resp.RecentSessions))
	}
	if resp.DateRange == nil {
		t.Error("expected date range")
	}
}

func TestListSessionsTool(t *testing.T) {
	s := testServer(t)

	// All sessions
	text := callTool(t, s, "list_sessions", nil)
	var sessions []sessionWithCountsBrief
	if err := json.Unmarshal([]byte(text), &sessions); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(sessions) != 3 {
		t.Errorf("got %d sessions, want 3", len(sessions))
	}

	// Filter by status
	text = callTool(t, s, "list_sessions", map[string]any{"status": "completed"})
	if err := json.Unmarshal([]byte(text), &sessions); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(sessions) != 1 {
		t.Errorf("got %d completed sessions, want 1", len(sessions))
	}

	// Limit
	text = callTool(t, s, "list_sessions", map[string]any{"limit": 1})
	if err := json.Unmarshal([]byte(text), &sessions); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(sessions) != 1 {
		t.Errorf("got %d sessions with limit=1, want 1", len(sessions))
	}
}

func TestGetSessionTool(t *testing.T) {
	s := testServer(t)

	text := callTool(t, s, "get_session", map[string]any{"session_id": "sess-1"})
	var detail sessionDetailResponse
	if err := json.Unmarshal([]byte(text), &detail); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if detail.ID != "sess-1" {
		t.Errorf("ID = %q, want sess-1", detail.ID)
	}
	if detail.Title != "Team Standup" {
		t.Errorf("Title = %q, want Team Standup", detail.Title)
	}
	if len(detail.Topics) != 2 {
		t.Errorf("Topics = %d, want 2", len(detail.Topics))
	}
	if detail.Summary == nil {
		t.Error("expected summary")
	}
	if detail.SegmentCount != 10 {
		t.Errorf("SegmentCount = %d, want 10", detail.SegmentCount)
	}
}

func TestGetTranscriptTool(t *testing.T) {
	s := testServer(t)

	// Default pagination
	text := callTool(t, s, "get_transcript", map[string]any{"session_id": "sess-1"})
	var segments []segmentResponse
	if err := json.Unmarshal([]byte(text), &segments); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(segments) != 10 {
		t.Errorf("got %d segments, want 10", len(segments))
	}

	// With limit
	text = callTool(t, s, "get_transcript", map[string]any{"session_id": "sess-1", "limit": 3})
	if err := json.Unmarshal([]byte(text), &segments); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(segments) != 3 {
		t.Errorf("got %d segments with limit=3, want 3", len(segments))
	}

	// With offset
	text = callTool(t, s, "get_transcript", map[string]any{"session_id": "sess-1", "limit": 3, "offset": 8})
	if err := json.Unmarshal([]byte(text), &segments); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(segments) != 2 {
		t.Errorf("got %d segments with offset=8, want 2", len(segments))
	}
}

func TestSearchTool(t *testing.T) {
	s := testServer(t)

	// Search segments
	text := callTool(t, s, "search", map[string]any{"query": "session one"})
	var results searchResponse
	if err := json.Unmarshal([]byte(text), &results); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(results.Segments) != 10 {
		t.Errorf("got %d segment results, want 10", len(results.Segments))
	}

	// Search topics
	text = callTool(t, s, "search", map[string]any{"query": "Sprint"})
	if err := json.Unmarshal([]byte(text), &results); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(results.Topics) != 1 {
		t.Errorf("got %d topic results, want 1", len(results.Topics))
	}

	// Search summaries
	text = callTool(t, s, "search", map[string]any{"query": "sprint goals"})
	if err := json.Unmarshal([]byte(text), &results); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(results.Summaries) != 1 {
		t.Errorf("got %d summary results, want 1", len(results.Summaries))
	}

	// Scoped to session
	text = callTool(t, s, "search", map[string]any{"query": "segment", "session_id": "sess-2"})
	if err := json.Unmarshal([]byte(text), &results); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(results.Segments) != 3 {
		t.Errorf("got %d scoped results, want 3", len(results.Segments))
	}
}
