# Real Audio Health Pulse + Self-Heal (#76, #32)

- Added an on-demand real speaker → air → mic health pulse command (`steno --health-pulse`) backed by a daemon `health_pulse` socket command.
- Added a production health pulse runner that speaks a nonce through `/usr/bin/say`, polls persisted transcript segments, and fuzzy-matches lossy ASR output instead of using synthetic/in-process audio.
- Added a health pulse coordinator with the issue #76 escalation ladder: rerun after capture-subsystem restart and surface a loud failure if recovery does not prove the pipeline.
- Wired automatic trigger hooks for startup, wake recovery, and default-input changes behind `settings.json` opt-in (`healthPulseAutomaticEnabled`) so the daemon does not unexpectedly speak unless configured.
- Extended daemon/TUI protocol types with queryable health-pulse result fields and tests for the coordinator and wire payloads.
