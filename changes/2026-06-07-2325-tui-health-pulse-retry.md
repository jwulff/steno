TUI health pulse trigger and bounded restart retry

- Added an `h` key in the TUI to run the daemon health pulse against the active recording session.
- Runs one health pulse after the TUI attaches to an active recording session, but only when the daemon reports the `healthPulseAutomaticEnabled` opt-in (added in the 2026-10-19 review pass).
- Restarts the daemon once and retries the health pulse once when the first attempt fails.
- Leaves a persistent warning after the retry fails instead of retrying indefinitely.
- Validates every required audio source: microphone is always required, and system audio is also required when system audio capture is enabled.
