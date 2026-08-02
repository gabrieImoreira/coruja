# sabia

A minimal, fully local macOS meeting recorder + transcriber, **tuned for
Portuguese**. One menu-bar click records your mic and all system audio as two
separate tracks; when you stop, sabia transcribes both on-device and writes a
speaker-tagged transcript. Nothing ever leaves the machine.

Fork of [digimata/quill](https://github.com/digimata/quill), same skeleton
(single Swift binary, menu-bar tray), swapping the default transcription
engine to **Whisper (WhisperKit)** so meetings in Portuguese (or any other
language Whisper covers) get transcribed properly — upstream quill's default
engine, Parakeet, is English-only.

Named for the *sabiá*, in the same feather/bird theme as quill and its
sibling [parrot](https://github.com/digimata/parrot).

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## Install — .app (recommended for most people)

1. Download `sabia-<version>-macos.zip` from
   [Releases](https://github.com/gabrieImoreira/sabia/releases), unzip it,
   and drag `Sabia.app` to `/Applications`.
2. **First launch only:** right-click `Sabia.app` → **Open** → **Open**
   again in the dialog. This app is ad-hoc signed but not notarized by
   Apple (that requires a paid Developer account), so a normal double-click
   on the first launch gets blocked by Gatekeeper as "from an unidentified
   developer" — right-click → Open bypasses that one time only. After the
   first launch, double-click works normally.
3. A waveform icon appears in the menu bar. Click it → **Start recording**.

To start automatically at login: System Settings → General → Login Items →
add `Sabia.app`.

### ⌃⌥⌘R — the reliable way to start/stop

macOS overlays third-party menu-bar icons with its own orange
microphone-in-use badge while recording (a privacy feature — every app that
records audio via a status-bar icon gets this, not a sabia bug). On a full
menu bar that badge can end up not forwarding clicks to the app underneath,
so relying on the icon alone to stop a recording isn't reliable. **⌃⌥⌘R
(Control+Option+Command+R) toggles recording from anywhere**, regardless of
whether the icon is visible or clickable, and a notification confirms
start/stop either way.

First use prompts for **Input Monitoring** permission (System Settings →
Privacy & Security → Input Monitoring) — required for any app-wide global
keyboard shortcut; harmless without a monitoring purpose, but a real
permission worth reading the prompt for.

### Automatic meeting detection (Google Meet / Teams in Chrome)

sabia polls Chrome's open tabs every 5 seconds for a Google Meet or
Microsoft Teams meeting URL. When one shows up, a small prompt appears in
the top-right corner — **Gravar** / **Ignorar**. Accept it and sabia starts
recording; when that same meeting's tab closes or navigates away, the
recording **stops automatically**.

There's no public macOS API for "a meeting is in progress," so this is a
URL-pattern heuristic — it can trigger on the pre-join lobby, not only an
actually-joined call. That's on purpose: detection only ever shows a
dismissable prompt, never starts recording by itself, so a false positive
costs a tap, not a surprise recording.

First poll triggers a one-time **"sabia wants to control Google Chrome"**
Automation permission prompt (System Settings → Privacy & Security →
Automation) — required for AppleScript to read tab URLs at all; without it,
detection silently does nothing (no crash, just no prompts).

A recording started manually (menu, Dock, or ⌃⌥⌘R) is never auto-stopped by
a Chrome tab closing — only a recording started *from the meeting prompt*
is tied to that meeting's lifecycle.

To build the `.app` yourself instead of downloading a release:

```sh
cd sabia
./scripts/build-app.sh        # -> .build/Sabia.app, .build/sabia-<version>-macos.zip
```

## Install — CLI binary (for terminal / LaunchAgent use)

```sh
cd sabia
swift build -c release
sudo cp .build/release/sabia /usr/local/bin/sabia
sabia install --launch-at-login   # optional — runs in the background on login
```

## How to use

1. **Run it** (`sabia` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Transcription

Built in, on-device, automatic. The default engine is **Whisper large-v3-turbo**
via [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)'s Core ML port
— multilingual, decoding in Portuguese by default (`transcription.language`,
default `"pt"`). Models (~1.5 GB) download once on first transcription;
`sabia doctor` reminds you to warm the cache before an important meeting.

**Parakeet TDT 0.6B v2** (English-only, via
[FluidAudio](https://github.com/FluidInference/FluidAudio), ~600 MB, faster —
roughly 20 seconds per hour of audio) is kept as an opt-in alternative for
English-only meetings — set `"engine": "parakeet"` in config.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol (`TranscriptionEngine`), so adding a
third engine is a self-contained file — see `WhisperEngine.swift` /
`ParakeetEngine.swift`.

### Accuracy vs. cloud transcription (e.g. coconote)

Whisper large-v3-turbo running locally does **solid** Portuguese transcription
for clear, single-speaker audio — but it's realistic to expect more mistakes
on proper nouns, jargon, and noisy/accented speech than a cloud service that
runs a bigger model and/or LLM post-processing on top. What you get in
exchange: **zero marginal cost per meeting** (no subscription, no per-minute
API billing) and **zero audio leaving the machine**. If accuracy on a specific
kind of meeting turns out to be the bottleneck, the natural next step is
post-processing `transcript.json` through an LLM pass (cleanup, punctuation,
custom vocabulary) — the engine boundary already isolates that from capture.

## Config

Optional, at `~/.config/sabia/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "whisper", "language": "pt" },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `transcription.engine` — `"whisper"` (default, multilingual) or `"parakeet"`
  (English-only, faster/smaller).
- `transcription.language` — ISO-639-1 code passed to Whisper's decoder.
  Default `"pt"`. Set `"auto"` to let Whisper detect the language per segment
  (useful for mixed-language meetings). Ignored by `parakeet`.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
sabia                        # run the menu-bar daemon (^C to quit)
sabia run --out <dir>        # custom recordings root (default ~/Recordings)
sabia doctor                 # check permissions, recordings folder, models
sabia install --launch-at-login
sabia install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **WhisperKit / Whisper large-v3-turbo** — on-device Core ML transcription (default, multilingual)
- **FluidAudio / Parakeet** — on-device Core ML transcription (opt-in, English-only)
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to sabia itself when running as a LaunchAgent.

## Relationship to upstream

This is a fork, not a drop-in replacement — the binary, bundle identifier
(`com.gabrieImoreira.sabia`), config path, and default engine all diverge from
quill so the two can coexist on the same machine. Recording/capture code is
unchanged from upstream; the divergence is entirely in the transcription
layer and naming. MIT license, same as upstream (see `LICENSE`).
