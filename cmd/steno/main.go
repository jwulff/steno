package main

import (
	"flag"
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/jwulff/steno/internal/db"
	stenoMCP "github.com/jwulff/steno/internal/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/jwulff/steno/internal/app"
)

func main() {
	mcpMode := flag.Bool("mcp", false, "Run as MCP stdio server (read-only database access)")
	flag.Parse()

	if *mcpMode {
		runMCP()
	} else {
		runTUI()
	}
}

func runTUI() {
	p := tea.NewProgram(
		app.New(),
		tea.WithAltScreen(),
	)

	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func runMCP() {
	dbPath := db.DefaultDBPath()
	if p := os.Getenv("STENO_DB"); p != "" {
		dbPath = p
	}

	if _, err := os.Stat(dbPath); os.IsNotExist(err) {
		fmt.Fprintf(os.Stderr, "steno: No steno database found at %s\nRun steno to start recording first.\n", dbPath)
		os.Exit(1)
	}

	store, err := db.Open(dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "steno: %v\n", err)
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

	stenoMCP.RegisterTools(s, store)

	if err := server.ServeStdio(s); err != nil {
		fmt.Fprintf(os.Stderr, "steno: %v\n", err)
		os.Exit(1)
	}
}
