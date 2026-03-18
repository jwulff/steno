package mcp

import (
	"context"
	"time"

	"github.com/jwulff/steno/internal/db"
	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

func registerOverview(s *server.MCPServer, store *db.Store) {
	tool := mcp.NewTool("get_overview",
		mcp.WithDescription("Get a high-level summary of the Steno database — total sessions, active session, recent sessions with topic counts, and date range. Start here to orient yourself."),
	)

	s.AddTool(tool, func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		overview, err := store.GetOverview()
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}
		return jsonResult(formatOverview(overview))
	})
}

type overviewResponse struct {
	TotalSessions  int                      `json:"total_sessions"`
	ActiveSession  *sessionBrief            `json:"active_session,omitempty"`
	RecentSessions []sessionWithCountsBrief `json:"recent_sessions"`
	DateRange      *dateRange               `json:"date_range,omitempty"`
}

type sessionBrief struct {
	ID        string  `json:"id"`
	Title     string  `json:"title,omitempty"`
	Status    string  `json:"status"`
	StartedAt string  `json:"started_at"`
	EndedAt   *string `json:"ended_at,omitempty"`
}

type sessionWithCountsBrief struct {
	sessionBrief
	SegmentCount int `json:"segment_count"`
	TopicCount   int `json:"topic_count"`
	SummaryCount int `json:"summary_count"`
}

type dateRange struct {
	Earliest string `json:"earliest"`
	Latest   string `json:"latest"`
}

func formatOverview(o *db.Overview) overviewResponse {
	resp := overviewResponse{
		TotalSessions: o.TotalSessions,
	}

	if o.ActiveSession != nil {
		resp.ActiveSession = formatSessionBrief(o.ActiveSession)
	}

	for _, swc := range o.RecentSessions {
		resp.RecentSessions = append(resp.RecentSessions, sessionWithCountsBrief{
			sessionBrief: *formatSessionBrief(&swc.Session),
			SegmentCount: swc.Counts.Segments,
			TopicCount:   swc.Counts.Topics,
			SummaryCount: swc.Counts.Summaries,
		})
	}
	if resp.RecentSessions == nil {
		resp.RecentSessions = []sessionWithCountsBrief{}
	}

	if o.EarliestSession != nil && o.LatestSession != nil {
		resp.DateRange = &dateRange{
			Earliest: o.EarliestSession.Format(time.RFC3339),
			Latest:   o.LatestSession.Format(time.RFC3339),
		}
	}

	return resp
}

func formatSessionBrief(s *db.Session) *sessionBrief {
	b := &sessionBrief{
		ID:        s.ID,
		Title:     s.Title,
		Status:    s.Status,
		StartedAt: s.StartedAt.Format(time.RFC3339),
	}
	if s.EndedAt != nil {
		e := s.EndedAt.Format(time.RFC3339)
		b.EndedAt = &e
	}
	return b
}
