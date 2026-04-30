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
//
// The legacy `i` / `I` (cycle input device) keybind was removed in the
// cluster-4 review pass: in always-on mode the TUI cannot synchronously
// re-route capture, so a local-only toggle drifted the visible device
// indicator from the actual capture device. The daemon already
// remembers `lastDevice` (U4 `StenoSettings`) and uses it on every
// successful start; users who want a different mic should select it as
// the macOS system default before launch, or wait for a future settings
// surface that issues a daemon-side pause/resume cycle with the new
// device.
//
// The legacy `a` / `A` (toggle system-audio capture) keybind was removed
// for the same reason: it only flipped a local boolean without sending
// any daemon command. The daemon's capture configuration is set at
// startup from `StenoSettings.lastSystemAudioEnabled` and is not
// toggleable mid-flight via the current protocol. Users who want to
// change the system-audio mode should edit
// `~/Library/Application Support/Steno/settings.json` and restart the
// daemon, or wait for a future protocol-level reconfigure command.
const (
	KeyQuit      = "q"
	KeyQuitUpper = "Q"
	KeyCtrlC     = "ctrl+c"
	KeySpace     = " "
	KeyTab       = "tab"
	KeyUp        = "up"
	KeyDown      = "down"
	KeyJ         = "j"
	KeyK         = "k"
	KeyEnter     = "enter"
	// U9 keybinds.
	KeyPause           = "p"
	KeyPauseIndefinite = "P"
	KeyErrorHistory    = "e"
	KeyErrorHistoryUp  = "E"
	KeyEsc             = "esc"
)
