package app

// Key binding constants used in handleKey.
//
// In the always-on world (U9):
//   - Space → demarcate (atomic session boundary), NOT start/stop.
//   - p     → toggle pause with 30-min auto-resume.
//   - P     → toggle pause indefinite (manual resume only).
//   - e     → toggle the error-history modal (last 10 non-transient errors).
//
// `start` and `stop` are still valid commands on the wire but no longer
// have keybinds — the daemon is always recording in the always-on model.
const (
	KeyQuit          = "q"
	KeyQuitUpper     = "Q"
	KeyCtrlC         = "ctrl+c"
	KeySpace         = " "
	KeyTab           = "tab"
	KeyUp            = "up"
	KeyDown          = "down"
	KeyJ             = "j"
	KeyK             = "k"
	KeyEnter         = "enter"
	KeyCycleDevice   = "i"
	KeyCycleDeviceUp = "I"
	KeyToggleSysAud  = "a"
	KeyToggleSysUp   = "A"
	// U9 keybinds.
	KeyPause          = "p"
	KeyPauseIndefinite = "P"
	KeyErrorHistory    = "e"
	KeyErrorHistoryUp  = "E"
	KeyEsc             = "esc"
)
