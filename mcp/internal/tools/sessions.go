package tools

import (
	"context"
	"fmt"
	"time"

	"github.com/jwulff/steno/mcp/internal/db"
	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

func registerSessions(s *server.MCPServer, store *db.Store) {
	// list_sessions
	listTool := mcp.NewTool("list_sessions",
		mcp.WithDescription("List recording sessions with optional filters. Returns sessions ordered by start time (newest first) with segment/topic/summary counts."),
		mcp.WithNumber("limit",
			mcp.Description("Maximum number of sessions to return (default 20, max 100)"),
		),
		mcp.WithString("status",
			mcp.Description("Filter by status"),
			mcp.Enum("active", "completed", "interrupted"),
		),
		mcp.WithString("after",
			mcp.Description("Only sessions started after this time (ISO 8601 / RFC3339)"),
		),
		mcp.WithString("before",
			mcp.Description("Only sessions started before this time (ISO 8601 / RFC3339)"),
		),
	)

	s.AddTool(listTool, func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		limit := clampLimit(req.GetInt("limit", 0), 20, 100)
		status := req.GetString("status", "")

		after, err := parseOptionalTime(req.GetString("after", ""))
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}
		before, err := parseOptionalTime(req.GetString("before", ""))
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}

		sessions, err := store.ListSessions(limit, before, after, status)
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}

		result := make([]sessionWithCountsBrief, 0, len(sessions))
		for _, swc := range sessions {
			result = append(result, sessionWithCountsBrief{
				sessionBrief: *formatSessionBrief(&swc.Session),
				SegmentCount: swc.Counts.Segments,
				TopicCount:   swc.Counts.Topics,
				SummaryCount: swc.Counts.Summaries,
			})
		}

		return jsonResult(result)
	})

	// get_session
	getTool := mcp.NewTool("get_session",
		mcp.WithDescription("Get detailed info about a single recording session, including all topics and the latest summary."),
		mcp.WithString("session_id",
			mcp.Required(),
			mcp.Description("The session ID to look up"),
		),
	)

	s.AddTool(getTool, func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		sessionID, err := req.RequireString("session_id")
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}

		sess, err := store.GetSession(sessionID)
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}
		if sess == nil {
			return mcp.NewToolResultError("session not found: " + sessionID), nil
		}

		topics, err := store.TopicsForSession(sessionID)
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}

		summary, err := store.LatestSummary(sessionID)
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}

		counts, err := store.SessionCounts(sessionID)
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}

		return jsonResult(formatSessionDetail(sess, topics, summary, counts))
	})
}

type sessionDetailResponse struct {
	ID           string          `json:"id"`
	Title        string          `json:"title,omitempty"`
	Status       string          `json:"status"`
	Locale       string          `json:"locale"`
	StartedAt    string          `json:"started_at"`
	EndedAt      *string         `json:"ended_at,omitempty"`
	SegmentCount int             `json:"segment_count"`
	TopicCount   int             `json:"topic_count"`
	SummaryCount int             `json:"summary_count"`
	Topics       []topicBrief    `json:"topics"`
	Summary      *summaryBrief   `json:"latest_summary,omitempty"`
}

type topicBrief struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Summary   string `json:"summary"`
	SegRange  string `json:"segment_range"`
	CreatedAt string `json:"created_at"`
}

type summaryBrief struct {
	ID          string `json:"id"`
	Content     string `json:"content"`
	SummaryType string `json:"summary_type"`
	SegRange    string `json:"segment_range"`
	CreatedAt   string `json:"created_at"`
}

func formatSessionDetail(s *db.Session, topics []db.Topic, summary *db.Summary, counts db.SessionCounts) sessionDetailResponse {
	resp := sessionDetailResponse{
		ID:           s.ID,
		Title:        s.Title,
		Status:       s.Status,
		Locale:       s.Locale,
		StartedAt:    s.StartedAt.Format(time.RFC3339),
		SegmentCount: counts.Segments,
		TopicCount:   counts.Topics,
		SummaryCount: counts.Summaries,
		Topics:       make([]topicBrief, 0, len(topics)),
	}

	if s.EndedAt != nil {
		e := s.EndedAt.Format(time.RFC3339)
		resp.EndedAt = &e
	}

	for _, t := range topics {
		resp.Topics = append(resp.Topics, topicBrief{
			ID:        t.ID,
			Title:     t.Title,
			Summary:   t.Summary,
			SegRange:  formatRange(t.SegmentRangeStart, t.SegmentRangeEnd),
			CreatedAt: t.CreatedAt.Format(time.RFC3339),
		})
	}

	if summary != nil {
		resp.Summary = &summaryBrief{
			ID:          summary.ID,
			Content:     summary.Content,
			SummaryType: summary.SummaryType,
			SegRange:    formatRange(summary.SegmentRangeStart, summary.SegmentRangeEnd),
			CreatedAt:   summary.CreatedAt.Format(time.RFC3339),
		}
	}

	return resp
}

func formatRange(start, end int) string {
	return fmt.Sprintf("%d-%d", start, end)
}
