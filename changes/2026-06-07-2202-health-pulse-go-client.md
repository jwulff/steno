# Health Pulse Go Client Surface (#78)

## Why

PR #78 adds an on-demand real speaker-to-mic health pulse in the daemon. The Go client/TUI binary needs protocol fields and a CLI entrypoint so users can request that pulse and inspect its structured result once the daemon-side handler is present.

## How

- Added optional health-pulse response and event fields to the Go daemon protocol mirror.
- Added `HealthPulseCmd()` for the `health_pulse` socket command.
- Added `steno --health-pulse`, which ensures the daemon is running, sends the command, prints a compact report, and exits non-zero on failure.
- Routed `health_pulse` daemon events through the TUI error surface so passing pulses are transient and failed pulses remain visible.

## Testing

- `go test ./...` in `cmd/steno`

## What's Next

Complete or merge the Swift daemon-side runner/coordinator from PR #78 so the new command returns live speaker-to-mic reports rather than an unsupported-command response from older daemons.
