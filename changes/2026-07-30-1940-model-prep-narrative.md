# Give the model download a beginning and an end

## Why

The first daemon start after a version change — or any start with a cold model cache —
logs roughly a minute of `FluidAudio.DownloadUtils` warnings while it fetches the
Sortformer v2.1 diarization model:

```
[WARN] [FluidAudio.DownloadUtils] Download attempt 1 for .../0-weight.bin failed:
  Downloaded artifact ... is invalid (empty file); refusing to cache it.. Retrying in 1.0s.
[WARN] [FluidAudio.DownloadUtils] First load failed: The file "1-weight.bin.partial" doesn't exist.
```

It reads like a broken install. It is a self-healing retry loop that settles on its own,
but nothing in the stream says so — and the natural reaction is to roll back a release
that is fine. Transcription genuinely doesn't work until it settles, so the symptom
overlaps with a real failure.

## How

The warnings themselves cannot be suppressed from here. FluidAudio's `AppLogger` mirrors
`warning` and `error` to the console in release builds and exposes no level control — only
`defaultSubsystem` is settable. Patching a dependency to quiet it is a worse trade than
explaining it.

So the fetch is bracketed by two lines that say what is happening:

```
[19:39:53] [INFO] [Steno] Preparing diarization models. A first run downloads them (~277MB)
  and retries transient failures — FluidAudio download warnings below are expected and
  self-healing. Transcription works without speaker labels until this finishes.
   … library warnings …
[19:40:51] [INFO] [Steno] Diarization models ready after 58.2s. Speaker labels are live.
```

and on genuine failure, a line that distinguishes it from the retries and says what still
works:

```
[ERROR] [Steno] Diarization models unavailable after 12.4s: <reason>.
  Recording and transcription continue without speaker labels.
```

`DaemonConsole` is new and deliberately narrow. `os.Logger` writes to unified logging only,
so a message sent there would not appear in the stream the operator is actually watching —
which is the whole problem. `DaemonConsole` writes to stdout in a shape comparable to the
library lines it sits among, and is reserved for a handful of lifecycle transitions.
Everything else stays on `os.Logger`.

## Key decisions

- **Explain rather than suppress.** Hiding third-party retry warnings would also hide the
  first sign of a genuinely stuck download. Framing them costs nothing and keeps the
  signal.
- **Report elapsed time on both paths.** "Ready after 58.2s" tells the operator the retries
  were the normal case; "unavailable after 12.4s" tells them it gave up early. The number
  is what separates the two stories.
- **Say what still works on failure.** The failure is a soft degrade — no speaker labels,
  everything else fine — and the message should stop someone from treating it as fatal.

## Testing

Verified against both cases on a real daemon, with the model cache moved aside for a
genuine cold fetch and restored afterwards:

- **Cold cache:** the preparing line lands first, the library's retry warnings follow it,
  and the sequence reads as one narrative instead of an unexplained wall of `[WARN]`.
- **Warm cache:** `Preparing…` → `Diarization models ready after 0.3s`.

`make test-daemon`: 502 passed, 0 failed.

## Correction to the issue

#93 claimed socket bring-up waits behind this fetch. It does not — `prepareDiarization`
already runs in a `Task.detached`. The cold-start delay observed separately comes from
auto-start awaiting the *transcription* model gate before the socket server starts, which
is a different model on a different path. The issue has been corrected.

Closes #93.
