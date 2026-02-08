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

	SourceLabelStyle = lipgloss.NewStyle().
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
)
