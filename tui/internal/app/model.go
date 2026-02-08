package app

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/jwulff/steno/tui/internal/daemon"
	"github.com/jwulff/steno/tui/internal/db"
	"github.com/jwulff/steno/tui/internal/ui"

	tea "github.com/charmbracelet/bubbletea"
)

// PanelFocus tracks which panel has keyboard focus.
type PanelFocus int

const (
	FocusTopics PanelFocus = iota
	FocusTranscript
)

// TranscriptEntry is a finalized transcript line for display.
type TranscriptEntry struct {
	Text      string
	Source    string
	Timestamp time.Time
	SeqNum   int
}

// TopicDisplay holds a topic for display in the topic panel.
type TopicDisplay struct {
	ID       string
	Title    string
	Summary  string
	Expanded bool
}

// Model is the root bubbletea model for the steno TUI.
type Model struct {
	// Connection state
	client    *daemon.Client // command connection
	evClient  *daemon.Client // event subscription connection
	connected bool
	connError string

	// Recording state
	recording    bool
	sessionID    string
	deviceName   string
	systemAudio  bool
	devices      []string
	deviceIndex  int

	// Transcript
	entries     []TranscriptEntry
	partialText string
	partialSrc  string

	// Audio levels
	micLevel float32
	sysLevel float32

	// Topics
	topics            []TopicDisplay
	selectedTopic     int
	modelProcessing   bool

	// UI state
	focusedPanel      PanelFocus
	width             int
	height            int
	transcriptScroll  int
	transcriptLive    bool
	topicScroll       int

	// Errors
	errorMessage      string
	errorTransient    bool

	// Status
	statusText        string

	// DB
	store             *db.Store

	// Reconnect
	reconnecting      bool
	reconnectAttempt  int
}

// New creates a new Model with default state.
func New() Model {
	return Model{
		statusText:     "Connecting to steno-daemon...",
		transcriptLive: true,
		focusedPanel:   FocusTranscript,
	}
}

// Init returns the initial command — connect to the daemon.
func (m Model) Init() tea.Cmd {
	return connectCmd()
}

// connectCmd attempts to connect to the daemon with two connections:
// one for commands, one for event subscription.
func connectCmd() tea.Cmd {
	return func() tea.Msg {
		sockPath := daemon.SocketPath()
		client, err := daemon.Connect(sockPath)
		if err != nil {
			return DaemonConnectErrorMsg{Err: err}
		}
		evClient, err := daemon.Connect(sockPath)
		if err != nil {
			client.Close()
			return DaemonConnectErrorMsg{Err: err}
		}
		return DaemonConnectedMsg{Client: client, EvClient: evClient}
	}
}

// subscribeCmd sends a subscribe command on the event client and starts reading events.
func subscribeCmd(evClient *daemon.Client) tea.Cmd {
	return func() tea.Msg {
		_, err := evClient.SendCommand(daemon.Command{Cmd: "subscribe"})
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return readEventCmd(evClient)()
	}
}

// readEventCmd reads the next event from the event client.
func readEventCmd(evClient *daemon.Client) tea.Cmd {
	return func() tea.Msg {
		ev, err := evClient.ReadEvent()
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return DaemonEventMsg{Event: ev}
	}
}

// statusCmd fetches daemon status.
func statusCmd(client *daemon.Client) tea.Cmd {
	return func() tea.Msg {
		resp, err := client.SendCommand(daemon.Command{Cmd: "status"})
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return StatusResponseMsg{Response: resp}
	}
}

// devicesCmd fetches available devices.
func devicesCmd(client *daemon.Client) tea.Cmd {
	return func() tea.Msg {
		resp, err := client.SendCommand(daemon.Command{Cmd: "devices"})
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return DevicesResponseMsg{Response: resp}
	}
}

// startCmd sends a start recording command.
func startCmd(client *daemon.Client, device string, sysAudio bool) tea.Cmd {
	return func() tea.Msg {
		cmd := daemon.Command{
			Cmd:         "start",
			Device:      device,
			SystemAudio: daemon.BoolPtr(sysAudio),
		}
		resp, err := client.SendCommand(cmd)
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return StartResponseMsg{Response: resp}
	}
}

// stopCmd sends a stop recording command.
func stopCmd(client *daemon.Client) tea.Cmd {
	return func() tea.Msg {
		resp, err := client.SendCommand(daemon.Command{Cmd: "stop"})
		if err != nil {
			return DaemonEventErrorMsg{Err: err}
		}
		return StopResponseMsg{Response: resp}
	}
}

// clearTransientErrorCmd fires after a delay to clear transient errors.
func clearTransientErrorCmd() tea.Cmd {
	return tea.Tick(5*time.Second, func(time.Time) tea.Msg {
		return ClearTransientErrorMsg{}
	})
}

// reconnectCmd schedules a reconnection attempt with exponential backoff.
func reconnectCmd(attempt int) tea.Cmd {
	delay := time.Duration(1<<min(attempt, 4)) * time.Second // 1s, 2s, 4s, 8s, 16s cap
	if delay > 30*time.Second {
		delay = 30 * time.Second
	}
	return tea.Tick(delay, func(time.Time) tea.Msg {
		return ReconnectTickMsg{}
	})
}

// loadTopicsCmd reads topics from SQLite for the given session.
func loadTopicsCmd(store *db.Store, sessionID string) tea.Cmd {
	return func() tea.Msg {
		topics, err := store.TopicsForSession(sessionID)
		if err != nil {
			return TopicsLoadedMsg{} // silently ignore DB errors
		}
		var loaded []TopicLoaded
		for _, t := range topics {
			loaded = append(loaded, TopicLoaded{
				ID:      t.ID,
				Title:   t.Title,
				Summary: t.Summary,
			})
		}
		return TopicsLoadedMsg{Topics: loaded}
	}
}

// openStoreCmd opens the SQLite store.
func openStoreCmd() tea.Cmd {
	return func() tea.Msg {
		store, err := db.Open(db.DefaultDBPath())
		if err != nil {
			return nil // silently ignore if DB not available yet
		}
		return storeOpenedMsg{store: store}
	}
}

type storeOpenedMsg struct{ store *db.Store }

// Update processes messages and returns the updated model and any commands.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.KeyMsg:
		return m.handleKey(msg)

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case DaemonConnectedMsg:
		m.client = msg.Client
		m.evClient = msg.EvClient
		m.connected = true
		m.connError = ""
		m.reconnecting = false
		m.reconnectAttempt = 0
		m.statusText = "Connected"
		// Subscribe on event client, fetch status/devices on command client
		return m, tea.Batch(
			subscribeCmd(m.evClient),
			statusCmd(m.client),
			devicesCmd(m.client),
			openStoreCmd(),
		)

	case DaemonConnectErrorMsg:
		m.connected = false
		m.connError = msg.Err.Error()
		m.reconnecting = true
		m.statusText = "Daemon not running. Reconnecting..."
		return m, reconnectCmd(m.reconnectAttempt)

	case StatusResponseMsg:
		r := msg.Response
		if r.Recording != nil {
			m.recording = *r.Recording
		}
		if r.SessionID != "" {
			m.sessionID = r.SessionID
		}
		if r.Device != "" {
			m.deviceName = r.Device
		}
		if r.SystemAudio != nil {
			m.systemAudio = *r.SystemAudio
		}
		if r.Status != "" {
			m.statusText = r.Status
		}
		return m, nil

	case DevicesResponseMsg:
		if msg.Response.Devices != nil {
			m.devices = msg.Response.Devices
		}
		return m, nil

	case StartResponseMsg:
		r := msg.Response
		if r.OK {
			m.recording = true
			if r.SessionID != "" {
				m.sessionID = r.SessionID
			}
			m.statusText = "Recording"
		} else {
			m.errorMessage = r.Error
			m.errorTransient = true
			return m, clearTransientErrorCmd()
		}
		return m, nil

	case StopResponseMsg:
		r := msg.Response
		if r.OK {
			m.recording = false
			m.partialText = ""
			m.partialSrc = ""
			m.statusText = "Idle"
		} else {
			m.errorMessage = r.Error
		}
		return m, nil

	case DaemonEventMsg:
		cmd := m.handleEvent(msg.Event)
		// Continue reading events on event client
		return m, tea.Batch(cmd, readEventCmd(m.evClient))

	case DaemonEventErrorMsg:
		m.connected = false
		m.connError = msg.Err.Error()
		m.statusText = "Disconnected. Reconnecting..."
		m.reconnecting = true
		if m.client != nil {
			m.client.Close()
			m.client = nil
		}
		if m.evClient != nil {
			m.evClient.Close()
			m.evClient = nil
		}
		return m, reconnectCmd(m.reconnectAttempt)

	case ReconnectTickMsg:
		m.reconnectAttempt++
		return m, connectCmd()

	case storeOpenedMsg:
		m.store = msg.store
		return m, nil

	case TopicsLoadedMsg:
		m.topics = m.topics[:0]
		for _, t := range msg.Topics {
			m.topics = append(m.topics, TopicDisplay{
				ID:      t.ID,
				Title:   t.Title,
				Summary: t.Summary,
			})
		}
		if m.selectedTopic >= len(m.topics) {
			m.selectedTopic = max(0, len(m.topics)-1)
		}
		return m, nil

	case ClearTransientErrorMsg:
		if m.errorTransient {
			m.errorMessage = ""
			m.errorTransient = false
		}
		return m, nil
	}

	return m, nil
}

// handleEvent processes a daemon event and returns any resulting command.
func (m *Model) handleEvent(ev daemon.Event) tea.Cmd {
	switch ev.Event {
	case "partial":
		m.partialText = ev.Text
		m.partialSrc = ev.Source

	case "segment":
		entry := TranscriptEntry{
			Text:      ev.Text,
			Source:    ev.Source,
			Timestamp: time.Now(),
		}
		if ev.SequenceNumber != nil {
			entry.SeqNum = *ev.SequenceNumber
		}
		m.entries = append(m.entries, entry)
		m.partialText = ""
		m.partialSrc = ""
		if m.transcriptLive {
			m.scrollToBottom()
		}

	case "level":
		if ev.Mic != nil {
			m.micLevel = *ev.Mic
		}
		if ev.Sys != nil {
			m.sysLevel = *ev.Sys
		}

	case "status":
		if ev.Recording != nil {
			m.recording = *ev.Recording
			if m.recording {
				m.statusText = "Recording"
			} else {
				m.statusText = "Idle"
				m.partialText = ""
			}
		}

	case "model_processing":
		if ev.ModelProcessing != nil {
			m.modelProcessing = *ev.ModelProcessing
		}

	case "topics":
		if m.store != nil && m.sessionID != "" {
			return loadTopicsCmd(m.store, m.sessionID)
		}
		return nil

	case "error":
		m.errorMessage = ev.Message
		if ev.Transient != nil && *ev.Transient {
			m.errorTransient = true
			return clearTransientErrorCmd()
		}
	}

	return nil
}

// handleKey processes key presses.
func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "q", "Q", "ctrl+c":
		if m.client != nil {
			m.client.Close()
		}
		if m.evClient != nil {
			m.evClient.Close()
		}
		return m, tea.Quit

	case " ":
		if !m.connected {
			return m, nil
		}
		if m.recording {
			return m, stopCmd(m.client)
		}
		device := ""
		if m.deviceIndex < len(m.devices) {
			device = m.devices[m.deviceIndex]
		}
		return m, startCmd(m.client, device, m.systemAudio)

	case "tab":
		if m.focusedPanel == FocusTopics {
			m.focusedPanel = FocusTranscript
		} else {
			m.focusedPanel = FocusTopics
		}
		return m, nil

	case "j":
		if m.focusedPanel == FocusTopics && len(m.topics) > 0 {
			if m.selectedTopic < len(m.topics)-1 {
				m.selectedTopic++
			}
		}
		return m, nil

	case "k":
		if m.focusedPanel == FocusTopics && len(m.topics) > 0 {
			if m.selectedTopic > 0 {
				m.selectedTopic--
			}
		}
		return m, nil

	case "enter":
		if m.focusedPanel == FocusTopics && m.selectedTopic < len(m.topics) {
			m.topics[m.selectedTopic].Expanded = !m.topics[m.selectedTopic].Expanded
		}
		return m, nil

	case "up":
		if m.focusedPanel == FocusTranscript {
			m.transcriptLive = false
			if m.transcriptScroll > 0 {
				m.transcriptScroll--
			}
		}
		return m, nil

	case "down":
		if m.focusedPanel == FocusTranscript {
			maxScroll := m.maxTranscriptScroll()
			m.transcriptScroll++
			if m.transcriptScroll >= maxScroll {
				m.transcriptScroll = maxScroll
				m.transcriptLive = true
			}
		}
		return m, nil

	case "i", "I":
		if !m.connected || len(m.devices) == 0 {
			return m, nil
		}
		m.deviceIndex = (m.deviceIndex + 1) % len(m.devices)
		m.deviceName = m.devices[m.deviceIndex]
		if m.recording {
			// Restart with new device
			return m, tea.Sequence(
				stopCmd(m.client),
				startCmd(m.client, m.deviceName, m.systemAudio),
			)
		}
		return m, nil

	case "a", "A":
		if !m.connected {
			return m, nil
		}
		m.systemAudio = !m.systemAudio
		if m.recording {
			return m, tea.Sequence(
				stopCmd(m.client),
				startCmd(m.client, m.deviceName, m.systemAudio),
			)
		}
		return m, nil
	}

	return m, nil
}

func (m *Model) scrollToBottom() {
	m.transcriptScroll = m.maxTranscriptScroll()
}

func (m Model) maxTranscriptScroll() int {
	totalLines := len(m.entries)
	if m.partialText != "" {
		totalLines++
	}
	visible := m.transcriptVisibleLines()
	if totalLines <= visible {
		return 0
	}
	return totalLines - visible
}

func (m Model) transcriptVisibleLines() int {
	if m.height == 0 {
		return 20
	}
	// Reserve: header(2) + status(1) + divider(1) + divider(1) + error(1) + footer(1) + padding
	reserved := 8
	return max(5, m.height-reserved)
}

func (m Model) topicPanelWidth() int {
	if m.width == 0 {
		return 30
	}
	return max(20, m.width*30/100)
}

func (m Model) transcriptPanelWidth() int {
	if m.width == 0 {
		return 60
	}
	return max(30, m.width-m.topicPanelWidth()-3)
}

// View renders the full TUI.
func (m Model) View() string {
	if m.width == 0 {
		return "Initializing..."
	}

	var sections []string

	// Header
	sections = append(sections, m.renderHeader())

	// Status bar
	sections = append(sections, m.renderStatusBar())

	// Divider
	sections = append(sections, ui.DividerStyle.Render(strings.Repeat("─", m.width)))

	// Main content: topics | transcript
	sections = append(sections, m.renderMainContent())

	// Divider
	sections = append(sections, ui.DividerStyle.Render(strings.Repeat("─", m.width)))

	// Error bar
	if m.errorMessage != "" {
		sections = append(sections, m.renderErrorBar())
	}

	// Footer
	sections = append(sections, m.renderFooter())

	return strings.Join(sections, "\n")
}

func (m Model) renderHeader() string {
	title := ui.TitleStyle.Render("STENO")

	var deviceInfo string
	if m.deviceName != "" {
		deviceInfo = ui.DimStyle.Render(" — " + m.deviceName)
	}

	var audioMode string
	if m.systemAudio {
		audioMode = ui.DimStyle.Render(" [MIC + SYS]")
	}

	return title + deviceInfo + audioMode
}

func (m Model) renderStatusBar() string {
	// Recording indicator
	var dot string
	if m.recording {
		dot = ui.RecordingDotStyle.Render("● REC")
	} else {
		dot = ui.IdleDotStyle.Render("○ IDLE")
	}

	// Level meters
	var levels string
	if m.recording {
		levels = "  " + renderLevelMeter("MIC", m.micLevel)
		if m.systemAudio {
			levels += "  " + renderLevelMeter("SYS", m.sysLevel)
		}
	}

	// Model processing indicator
	var processing string
	if m.modelProcessing {
		processing = "  " + ui.SpinnerStyle.Render("⟳ AI")
	}

	return dot + levels + processing
}

func renderLevelMeter(label string, level float32) string {
	const barLen = 8
	filled := int(level * barLen)
	if filled > barLen {
		filled = barLen
	}

	var bar string
	for i := 0; i < barLen; i++ {
		if i < filled {
			pct := float32(i) / float32(barLen)
			if pct > 0.6 {
				bar += ui.LevelYellowStyle.Render("█")
			} else {
				bar += ui.LevelGreenStyle.Render("█")
			}
		} else {
			bar += ui.LevelGrayStyle.Render("░")
		}
	}

	var styledLabel string
	if label == "SYS" {
		styledLabel = ui.SysLabelStyle.Render(label)
	} else {
		styledLabel = ui.MicLabelStyle.Render(label)
	}
	return styledLabel + " " + bar
}

func (m Model) renderMainContent() string {
	topicW := m.topicPanelWidth()
	transcriptW := m.transcriptPanelWidth()
	contentH := m.transcriptVisibleLines()

	topicPanel := m.renderTopicPanel(topicW, contentH)
	transcriptPanel := m.renderTranscriptPanel(transcriptW, contentH)

	divider := ui.DividerStyle.Render("│")

	// Join panels side by side
	topicLines := strings.Split(topicPanel, "\n")
	transcriptLines := strings.Split(transcriptPanel, "\n")

	// Pad to same height
	for len(topicLines) < contentH {
		topicLines = append(topicLines, strings.Repeat(" ", topicW))
	}
	for len(transcriptLines) < contentH {
		transcriptLines = append(transcriptLines, "")
	}

	var rows []string
	for i := 0; i < contentH; i++ {
		tl := topicLines[i]
		tr := ""
		if i < len(transcriptLines) {
			tr = transcriptLines[i]
		}
		rows = append(rows, tl+divider+tr)
	}

	return strings.Join(rows, "\n")
}

func (m Model) renderTopicPanel(width, height int) string {
	// Header
	var header string
	if m.focusedPanel == FocusTopics {
		header = ui.PanelTitleActiveStyle.Render(fmt.Sprintf("TOPICS (%d)", len(m.topics)))
	} else {
		header = ui.PanelTitleStyle.Render(fmt.Sprintf("TOPICS (%d)", len(m.topics)))
	}
	header = padRight(header, width)

	var lines []string
	lines = append(lines, header)

	if len(m.topics) == 0 {
		lines = append(lines, ui.DimStyle.Render("  No topics yet..."))
		lines = append(lines, ui.DimStyle.Render("  Topics appear as you speak"))
	} else {
		for i, topic := range m.topics {
			isSelected := i == m.selectedTopic
			expandMarker := "▸"
			if topic.Expanded {
				expandMarker = "▾"
			}

			var line string
			if isSelected && m.focusedPanel == FocusTopics {
				line = ui.SelectedStyle.Render("> "+expandMarker+" ") + ui.SelectedStyle.Render(topic.Title)
			} else {
				line = "  " + expandMarker + " " + topic.Title
			}
			lines = append(lines, truncateToWidth(line, width))

			if topic.Expanded {
				wrapped := wrapText(topic.Summary, max(10, width-6))
				for _, wl := range wrapped {
					lines = append(lines, ui.DimStyle.Render("    "+wl))
				}
			}
		}
	}

	// Pad to height
	for len(lines) < height {
		lines = append(lines, strings.Repeat(" ", width))
	}
	if len(lines) > height {
		lines = lines[:height]
	}

	// Ensure each line is padded to width
	for i, l := range lines {
		lines[i] = padRight(l, width)
	}

	return strings.Join(lines, "\n")
}

func (m Model) renderTranscriptPanel(width, height int) string {
	// Header
	var header string
	var badge string
	if m.transcriptLive {
		badge = ui.LiveBadgeStyle.Render(" LIVE")
	} else {
		badge = ui.ScrollBadgeStyle.Render(" SCROLL")
	}

	if m.focusedPanel == FocusTranscript {
		header = ui.PanelTitleActiveStyle.Render("TRANSCRIPT") + badge
	} else {
		header = ui.PanelTitleStyle.Render("TRANSCRIPT") + badge
	}

	var lines []string
	lines = append(lines, header)

	contentHeight := height - 1 // subtract header line

	if !m.connected {
		if m.reconnecting {
			lines = append(lines, "")
			lines = append(lines, ui.ErrorTextStyle.Render("  Daemon disconnected. Reconnecting..."))
		} else if m.connError != "" {
			lines = append(lines, "")
			lines = append(lines, ui.ErrorStyle.Render("  Daemon not running."))
			lines = append(lines, ui.DimStyle.Render("  Start with: steno-daemon run"))
		} else {
			lines = append(lines, ui.DimStyle.Render("  Connecting to steno-daemon..."))
		}
	} else if len(m.entries) == 0 && m.partialText == "" {
		lines = append(lines, "")
		lines = append(lines, ui.DimStyle.Render("  Press Space to start recording"))
	} else {
		// Build display lines from entries, wrapping long text
		// Prefix: "  [HH:MM:SS] [MIC] " = ~22 chars visible
		prefixWidth := 22
		textWidth := max(10, width-prefixWidth-2) // -2 for leading indent
		indentStr := strings.Repeat(" ", prefixWidth)

		var displayLines []string
		for _, e := range m.entries {
			ts := ui.TimestampStyle.Render(e.Timestamp.Format("[15:04:05]"))
			var src string
			if e.Source == "systemAudio" {
				src = ui.SysLabelStyle.Render("[SYS] ")
			} else {
				src = ui.MicLabelStyle.Render("[MIC] ")
			}
			wrapped := wrapText(e.Text, textWidth)
			displayLines = append(displayLines, ts+" "+src+wrapped[0])
			for _, wl := range wrapped[1:] {
				displayLines = append(displayLines, indentStr+wl)
			}
		}

		// Partial text
		if m.partialText != "" {
			ts := ui.TimestampStyle.Render(time.Now().Format("[15:04:05]"))
			src := ui.PartialTextStyle.Render("[MIC] ")
			if m.partialSrc == "systemAudio" {
				src = ui.PartialTextStyle.Render("[SYS] ")
			}
			wrapped := wrapText(m.partialText+"▌", textWidth)
			partial := ui.PartialTextStyle.Render(wrapped[0])
			displayLines = append(displayLines, ts+" "+src+partial)
			for _, wl := range wrapped[1:] {
				displayLines = append(displayLines, indentStr+ui.PartialTextStyle.Render(wl))
			}
		}

		// Apply scroll
		start := 0
		if m.transcriptLive {
			if len(displayLines) > contentHeight {
				start = len(displayLines) - contentHeight
			}
		} else {
			start = m.transcriptScroll
		}
		if start < 0 {
			start = 0
		}

		end := start + contentHeight
		if end > len(displayLines) {
			end = len(displayLines)
		}

		for i := start; i < end; i++ {
			lines = append(lines, "  "+displayLines[i])
		}
	}

	// Pad to height
	for len(lines) < height {
		lines = append(lines, "")
	}
	if len(lines) > height {
		lines = lines[:height]
	}

	return strings.Join(lines, "\n")
}

func (m Model) renderErrorBar() string {
	return ui.ErrorStyle.Render("Error: ") + ui.ErrorTextStyle.Render(m.errorMessage)
}

func (m Model) renderFooter() string {
	var parts []string

	if m.connected {
		if m.recording {
			parts = append(parts, ui.FooterKeyStyle.Render("Space")+ui.FooterDescStyle.Render(" Stop"))
		} else {
			parts = append(parts, ui.FooterKeyStyle.Render("Space")+ui.FooterDescStyle.Render(" Record"))
		}
		parts = append(parts, ui.FooterKeyStyle.Render("i")+ui.FooterDescStyle.Render(" Device"))
		parts = append(parts, ui.FooterKeyStyle.Render("a")+ui.FooterDescStyle.Render(" SysAudio"))
		parts = append(parts, ui.FooterKeyStyle.Render("Tab")+ui.FooterDescStyle.Render(" Focus"))
		parts = append(parts, ui.FooterKeyStyle.Render("j/k")+ui.FooterDescStyle.Render(" Nav"))
		parts = append(parts, ui.FooterKeyStyle.Render("↑↓")+ui.FooterDescStyle.Render(" Scroll"))
	}

	parts = append(parts, ui.FooterKeyStyle.Render("q")+ui.FooterDescStyle.Render(" Quit"))

	return strings.Join(parts, "  ")
}

// Helpers

func padRight(s string, width int) string {
	// Get visible length (ignoring ANSI codes)
	visible := lipgloss.Width(s)
	if visible >= width {
		return s
	}
	return s + strings.Repeat(" ", width-visible)
}

func truncateToWidth(s string, width int) string {
	visible := lipgloss.Width(s)
	if visible <= width {
		return s
	}
	// Simple truncation for non-styled strings
	runes := []rune(s)
	if len(runes) > width-1 {
		return string(runes[:width-1]) + "…"
	}
	return s
}

func wrapText(text string, width int) []string {
	if width <= 0 {
		return []string{text}
	}

	var lines []string
	for _, paragraph := range strings.Split(text, "\n") {
		var current string
		for _, word := range strings.Fields(paragraph) {
			if current == "" {
				current = word
			} else if len(current)+1+len(word) <= width {
				current += " " + word
			} else {
				lines = append(lines, current)
				current = word
			}
		}
		if current != "" {
			lines = append(lines, current)
		} else {
			lines = append(lines, "")
		}
	}
	if len(lines) == 0 {
		return []string{""}
	}
	return lines
}
