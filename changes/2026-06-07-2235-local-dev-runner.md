# Local Dev Runner

## Why

Testing daemon/client changes locally required a fragile sequence of commands:
build the debug daemon, build the Go TUI, stop any installed or lingering daemon,
then remember to point the local client at the freshly built daemon.

## How

- Added `scripts/run-local`, which finds the Steno repo root from any working-tree
  directory, builds the debug daemon and Go TUI, unloads the user launchd daemon
  if present, stops exact-name `steno-daemon` processes, clears stale pid/socket
  files, and runs the local `steno` binary with `STENO_DAEMON_PATH` set.
- Added `make run-local` as a root-level shortcut.
- Documented the local runner and its `--health-pulse` pass-through usage.

## Testing

- `bash -n scripts/run-local`
