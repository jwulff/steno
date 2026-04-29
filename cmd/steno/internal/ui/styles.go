package ui

import "github.com/charmbracelet/lipgloss"

// Colors used throughout the TUI.
var (
	ColorRed     = lipgloss.Color("#FF0000")
	ColorGreen   = lipgloss.Color("#00FF00")
	ColorYellow  = lipgloss.Color("#FFFF00")
	ColorCyan    = lipgloss.Color("#00FFFF")
	ColorGray    = lipgloss.Color("#666666")
	ColorDimGray = lipgloss.Color("#444444")
	ColorWhite   = lipgloss.Color("#FFFFFF")
	ColorMagenta = lipgloss.Color("#FF00FF")
)

// Base styles reused by UI components.
var (
	TitleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(ColorCyan)

	HeaderStyle = lipgloss.NewStyle().
			Foreground(ColorCyan)

	StatusStyle = lipgloss.NewStyle().
			Foreground(ColorGray)

	RecordingDotStyle = lipgloss.NewStyle().
				Foreground(ColorRed).
				Bold(true)

	IdleDotStyle = lipgloss.NewStyle().
			Foreground(ColorGray)

	ErrorStyle = lipgloss.NewStyle().
			Foreground(ColorRed).
			Bold(true)

	ErrorTextStyle = lipgloss.NewStyle().
			Foreground(ColorRed)

	PartialTextStyle = lipgloss.NewStyle().
				Foreground(ColorYellow)

	TimestampStyle = lipgloss.NewStyle().
			Foreground(ColorGray)

	MicLabelStyle = lipgloss.NewStyle().
			Foreground(ColorGreen)

	SysLabelStyle = lipgloss.NewStyle().
			Foreground(ColorCyan)

	PanelTitleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(ColorWhite)

	PanelTitleActiveStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(ColorCyan)

	SelectedStyle = lipgloss.NewStyle().
			Foreground(ColorCyan).
			Bold(true)

	DimStyle = lipgloss.NewStyle().
			Foreground(ColorGray)

	FooterKeyStyle = lipgloss.NewStyle().
			Foreground(ColorYellow).
			Bold(true)

	FooterDescStyle = lipgloss.NewStyle().
			Foreground(ColorGray)

	DividerStyle = lipgloss.NewStyle().
			Foreground(ColorDimGray)

	LevelGreenStyle = lipgloss.NewStyle().
			Foreground(ColorGreen)

	LevelYellowStyle = lipgloss.NewStyle().
				Foreground(ColorYellow)

	LevelGrayStyle = lipgloss.NewStyle().
			Foreground(ColorGray)

	LiveBadgeStyle = lipgloss.NewStyle().
			Foreground(ColorGreen).
			Bold(true)

	ScrollBadgeStyle = lipgloss.NewStyle().
				Foreground(ColorYellow).
				Bold(true)

	SpinnerStyle = lipgloss.NewStyle().
			Foreground(ColorMagenta)

	MagentaStyle = lipgloss.NewStyle().
			Foreground(ColorMagenta).
			Bold(true)

	// U9 — health-surface state styles.

	// PausedStyle: blue/cyan paused indicator.
	PausedStyle = lipgloss.NewStyle().
			Foreground(ColorCyan).
			Bold(true)

	// RecoveringStyle: yellow ⚠ for in-progress pipeline restart (transient).
	RecoveringStyle = lipgloss.NewStyle().
			Foreground(ColorYellow).
			Bold(true)

	// FailedStyle: red ✗ for non-transient surrender.
	FailedStyle = lipgloss.NewStyle().
			Foreground(ColorRed).
			Bold(true)

	// DisconnectedStyle: gray ◌ for daemon socket lost / TUI-side reconnect.
	// Visually distinct from RECOVERING (which is daemon-internal).
	DisconnectedStyle = lipgloss.NewStyle().
				Foreground(ColorGray).
				Bold(true)

	// LastSegWarnStyle: yellow text for the "last segment Ns ago" annotation
	// when N >= 60s while not paused.
	LastSegWarnStyle = lipgloss.NewStyle().
				Foreground(ColorYellow)

	// HealMarkerStyle: dim yellow inline annotation in the segment timeline.
	HealMarkerStyle = lipgloss.NewStyle().
			Foreground(ColorYellow).
			Italic(true)

	// FirstLaunchBannerStyle: cyan banner for the consent disclosure on
	// first launch.
	FirstLaunchBannerStyle = lipgloss.NewStyle().
				Foreground(ColorCyan).
				Bold(true).
				Border(lipgloss.NormalBorder()).
				BorderForeground(ColorCyan).
				Padding(0, 1)

	// ErrorModalStyle: bordered overlay for the `e` error-history modal.
	ErrorModalStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(ColorRed).
			Padding(0, 1)
)
