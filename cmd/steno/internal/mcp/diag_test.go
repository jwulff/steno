package mcp

import (
	"fmt"
	"testing"
)

func TestDiagGetTranscript(t *testing.T) {
	s := testServer(t)
	text := callTool(t, s, "get_transcript", map[string]any{"session_id": "sess-1"})
	fmt.Printf("RESULT: %q\n", text)
}
