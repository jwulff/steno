package main

import (
	"fmt"
	"os"

	"github.com/jwulff/steno/mcp/internal/db"
	"github.com/jwulff/steno/mcp/internal/tools"
	"github.com/mark3labs/mcp-go/server"
)

func main() {
	dbPath := db.DefaultDBPath()
	if p := os.Getenv("STENO_DB"); p != "" {
		dbPath = p
	}

	store, err := db.Open(dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "steno-mcp: %v\n", err)
		os.Exit(1)
	}
	defer store.Close()

	s := server.NewMCPServer(
		"steno-mcp",
		"0.1.0",
		server.WithToolCapabilities(false),
		server.WithInstructions("Steno MCP server provides read-only access to the Steno speech-to-text database. "+
			"Use get_overview first to orient yourself, then drill into sessions with list_sessions and get_session, "+
			"read transcripts with get_transcript, and search across all data with search."),
	)

	tools.RegisterTools(s, store)

	if err := server.ServeStdio(s); err != nil {
		fmt.Fprintf(os.Stderr, "steno-mcp: %v\n", err)
		os.Exit(1)
	}
}
