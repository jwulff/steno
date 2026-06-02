# Daemon health indicator + restart control

## Why

The app is a thin client of `steno-daemon`. When the daemon gets stuck, loses
microphone/screen permission, or lands in an error state, the user had no in-app
way to see why or to recover — they had to drop to a terminal and `pkill` it.
This adds health monitoring and a one-click restart.

There's a second benefit tied to macOS permissions: TCC attributes mic/screen
access to the *responsible* (launching) process. A daemon previously launched by
Terminal carries Terminal's grant; when Steno launches it, that grant doesn't
apply. Restarting the daemon *from the app* makes the app the responsible
process, which is often what unsticks a permission-denied recorder.

Closes #75.

## How

- **`DaemonController`** (StenoCore) inspects and controls the daemon process:
  reads the PID file, checks liveness (`kill(pid, 0)`), and confirms the PID is
  actually `steno-daemon` via `proc_pidpath` before signaling. `stop()` is a
  graceful SIGTERM escalating to SIGKILL; `restart()` stops then relaunches via
  the existing `DaemonLauncher` and waits for the socket.
- **`AppModel`** gains a derived `daemonHealth`
  (healthy / paused / recovering / error / unreachable / stopped / restarting /
  connecting), polled every 3s for process liveness + PID, and a
  `restartDaemon()` intent that tears the connection down, restarts the process,
  and reconnects.
- **UI**: an engine-health chip in the status header (color + icon by severity),
  opening a popover with process/socket/engine detail, last error, a **Restart
  Engine** button, and an Open Privacy Settings shortcut when in error. The
  menu-bar popover gets a health line and a restart button too.

## Key Decisions

- **PID-reuse safety.** The controller never signals a PID it can't confirm is
  `steno-daemon` (verified by executable path), mirroring the Go manager's
  conservative ghost-recovery — better to leave a stale PID file than to kill an
  unrelated process that reused the number.
- **Single spawn owner.** Restart cancels the reconnect loop, stops the process,
  then calls `start()` to spin a fresh connect loop — so process spawning has one
  owner and two relaunch paths never race into a double-spawn.
- **Pure health derivation.** `AppModel.daemonHealth(status:processRunning:restarting:)`
  is a static pure function, unit-tested independent of the UI.

## Verification

- `make test-app` → 43 tests pass (adds PID parsing + health-derivation cases).
- `make build-app` → clean release build, zero warnings.
- Launched the app: the health chip showed **Healthy** beside a **Recording**
  pill against a freshly app-launched daemon — confirming the indicator and that
  app-launched capture works (the responsible-process permission benefit above).
