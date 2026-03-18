// Package tools registers MCP tool handlers for querying the steno database.
package mcp

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/jwulff/steno/internal/db"
	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

// RegisterTools adds all steno tools to the MCP server.
func RegisterTools(s *server.MCPServer, store *db.Store) {
	registerOverview(s, store)
	registerSessions(s, store)
	registerTranscript(s, store)
	registerSearch(s, store)
}

// clampLimit constrains a limit value between 1 and max, defaulting to def.
func clampLimit(val, def, max int) int {
	if val <= 0 {
		return def
	}
	if val > max {
		return max
	}
	return val
}

// parseOptionalTime parses an ISO 8601 string into a *time.Time, or returns nil.
func parseOptionalTime(s string) (*time.Time, error) {
	if s == "" {
		return nil, nil
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return nil, fmt.Errorf("invalid timestamp %q: expected ISO 8601 (RFC3339) format", s)
	}
	return &t, nil
}

// jsonResult marshals v and returns it as a text tool result.
func jsonResult(v any) (*mcp.CallToolResult, error) {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal result: %w", err)
	}
	return mcp.NewToolResultText(string(data)), nil
}
