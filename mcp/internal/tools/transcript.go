package tools

import (
	"context"
	"time"

	"github.com/jwulff/steno/mcp/internal/db"
	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

func registerTranscript(s *server.MCPServer, store *db.Store) {
	tool := mcp.NewTool("get_transcript",
		mcp.WithDescription("Read transcript segments for a session. Returns text with timestamps, source (microphone/systemAudio), and confidence scores. Supports pagination and time-window filtering."),
		mcp.WithString("session_id",
			mcp.Required(),
			mcp.Description("The session ID to get transcript for"),
		),
		mcp.WithString("after",
			mcp.Description("Only segments after this time (ISO 8601 / RFC3339)"),
		),
		mcp.WithString("before",
			mcp.Description("Only segments before this time (ISO 8601 / RFC3339)"),
		),
		mcp.WithNumber("limit",
			mcp.Description("Maximum segments to return (default 100, max 500)"),
		),
		mcp.WithNumber("offset",
			mcp.Description("Number of segments to skip for pagination (default 0)"),
		),
	)

	s.AddTool(tool, func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		sessionID, err := req.RequireString("session_id")
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}

		after, err := parseOptionalTime(req.GetString("after", ""))
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}
		before, err := parseOptionalTime(req.GetString("before", ""))
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}

		var segments []db.Segment

		if after != nil || before != nil {
			segments, err = store.SegmentsForTimeRange(sessionID, after, before)
		} else {
			limit := clampLimit(req.GetInt("limit", 0), 100, 500)
			offset := req.GetInt("offset", 0)
			if offset < 0 {
				offset = 0
			}
			segments, err = store.SegmentsForSession(sessionID, limit, offset)
		}

		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}

		result := make([]segmentResponse, 0, len(segments))
		for _, seg := range segments {
			result = append(result, formatSegment(seg))
		}

		return jsonResult(result)
	})
}

type segmentResponse struct {
	ID             string   `json:"id"`
	SessionID      string   `json:"session_id"`
	Text           string   `json:"text"`
	Source         string   `json:"source"`
	SequenceNumber int      `json:"sequence_number"`
	StartedAt      string   `json:"started_at"`
	EndedAt        string   `json:"ended_at"`
	Confidence     *float64 `json:"confidence,omitempty"`
}

func formatSegment(seg db.Segment) segmentResponse {
	return segmentResponse{
		ID:             seg.ID,
		SessionID:      seg.SessionID,
		Text:           seg.Text,
		Source:         seg.Source,
		SequenceNumber: seg.SequenceNumber,
		StartedAt:      seg.StartedAt.Format(time.RFC3339),
		EndedAt:        seg.EndedAt.Format(time.RFC3339),
		Confidence:     seg.Confidence,
	}
}
