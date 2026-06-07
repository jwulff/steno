package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/jwulff/steno/internal/db"
	stenoMCP "github.com/jwulff/steno/internal/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/jwulff/steno/internal/app"
	"github.com/jwulff/steno/internal/daemon"
)

func main() {
	mcpMode := flag.Bool("mcp", false, "Run as MCP stdio server (read-only database access)")
	healthPulse := flag.Bool("health-pulse", false, "Run the real speaker-to-mic audio health pulse and print the result")
	flag.Parse()

	if *healthPulse {
		runHealthPulse()
	} else if *mcpMode {
		runMCP()
	} else {
		runTUI()
	}
}

func runHealthPulse() {
	mgr := daemon.NewManager()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := mgr.EnsureRunning(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "steno: %v\n", err)
		os.Exit(1)
	}

	client, err := daemon.Connect(daemon.SocketPath())
	if err != nil {
		fmt.Fprintf(os.Stderr, "steno: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	resp, err := client.SendCommand(daemon.HealthPulseCmd())
	if err != nil {
		fmt.Fprintf(os.Stderr, "steno: %v\n", err)
		os.Exit(1)
	}

	if resp.HealthPulseOK != nil && *resp.HealthPulseOK {
		fmt.Println("Health pulse passed")
	} else {
		fmt.Println("Health pulse failed")
	}
	if resp.HealthPulseState != "" {
		fmt.Printf("state: %s\n", resp.HealthPulseState)
	}
	if resp.HealthPulseSimilarity != nil || resp.HealthPulseThreshold != nil {
		similarity := "n/a"
		threshold := "n/a"
		if resp.HealthPulseSimilarity != nil {
			similarity = fmt.Sprintf("%.2f", *resp.HealthPulseSimilarity)
		}
		if resp.HealthPulseThreshold != nil {
			threshold = fmt.Sprintf("%.2f", *resp.HealthPulseThreshold)
		}
		fmt.Printf("similarity: %s (threshold %s)\n", similarity, threshold)
	}
	if resp.HealthPulseObserved != "" {
		fmt.Printf("observed: %s\n", resp.HealthPulseObserved)
	}
	if resp.Error != "" {
		fmt.Fprintf(os.Stderr, "steno: %s\n", resp.Error)
	}
	if resp.HealthPulseOK == nil || !*resp.HealthPulseOK {
		os.Exit(1)
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
