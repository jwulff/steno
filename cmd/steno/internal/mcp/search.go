package mcp

import (
	"context"
	"time"

	"github.com/jwulff/steno/internal/db"
	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

func registerSearch(s *server.MCPServer, store *db.Store) {
	tool := mcp.NewTool("search",
		mcp.WithDescription("Search across transcript segments, topics, and summaries by keyword. Returns matches grouped by type, each with its session ID."),
		mcp.WithString("query",
			mcp.Required(),
			mcp.Description("Search text (matched with SQL LIKE)"),
		),
		mcp.WithString("session_id",
			mcp.Description("Scope search to a specific session"),
		),
		mcp.WithNumber("limit",
			mcp.Description("Maximum results per type (default 20, max 100)"),
		),
	)

	s.AddTool(tool, func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		query, err := req.RequireString("query")
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}

		sessionID := req.GetString("session_id", "")
		limit := clampLimit(req.GetInt("limit", 0), 20, 100)

		segments, err := store.SearchSegments(query, sessionID, limit)
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}

		topics, err := store.SearchTopics(query, limit)
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}

		summaries, err := store.SearchSummaries(query, sessionID, limit)
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}

		return jsonResult(formatSearchResults(segments, topics, summaries))
	})
}

type searchResponse struct {
	Segments  []searchSegment  `json:"segments"`
	Topics    []searchTopic    `json:"topics"`
	Summaries []searchSummary  `json:"summaries"`
}

type searchSegment struct {
	ID        string   `json:"id"`
	SessionID string   `json:"session_id"`
	Text      string   `json:"text"`
	Source    string   `json:"source"`
	StartedAt string   `json:"started_at"`
	Confidence *float64 `json:"confidence,omitempty"`
}

type searchTopic struct {
	ID        string `json:"id"`
	SessionID string `json:"session_id"`
	Title     string `json:"title"`
	Summary   string `json:"summary"`
	CreatedAt string `json:"created_at"`
}

type searchSummary struct {
	ID          string `json:"id"`
	SessionID   string `json:"session_id"`
	Content     string `json:"content"`
	SummaryType string `json:"summary_type"`
	CreatedAt   string `json:"created_at"`
}

func formatSearchResults(segments []db.Segment, topics []db.Topic, summaries []db.Summary) searchResponse {
	resp := searchResponse{
		Segments:  make([]searchSegment, 0, len(segments)),
		Topics:    make([]searchTopic, 0, len(topics)),
		Summaries: make([]searchSummary, 0, len(summaries)),
	}

	for _, seg := range segments {
		resp.Segments = append(resp.Segments, searchSegment{
			ID:         seg.ID,
			SessionID:  seg.SessionID,
			Text:       seg.Text,
			Source:     seg.Source,
			StartedAt:  seg.StartedAt.Format(time.RFC3339),
			Confidence: seg.Confidence,
		})
	}

	for _, t := range topics {
		resp.Topics = append(resp.Topics, searchTopic{
			ID:        t.ID,
			SessionID: t.SessionID,
			Title:     t.Title,
			Summary:   t.Summary,
			CreatedAt: t.CreatedAt.Format(time.RFC3339),
		})
	}

	for _, s := range summaries {
		resp.Summaries = append(resp.Summaries, searchSummary{
			ID:          s.ID,
			SessionID:   s.SessionID,
			Content:     s.Content,
			SummaryType: s.SummaryType,
			CreatedAt:   s.CreatedAt.Format(time.RFC3339),
		})
	}

	return resp
}
