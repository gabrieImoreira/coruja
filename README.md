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
3. A waveform icon appears in **both** the menu bar and the Dock. Click
   either → **Start recording** (or open the Dock icon for the full notes
   window — session list + transcript reader + a record/stop button, no
   different from opening any other app).

To start automatically at login: System Settings → General → Login Items →
add `Sabia.app`.

### Why there's a Dock icon at all

Upstream quill is deliberately menu-bar-only, no Dock icon. sabia keeps a
**permanent Dock icon** instead, for a concrete reason found the hard way:
macOS will silently drop a third-party menu bar icon when the bar is full —
no warning, no overflow chevron on some setups — and separately overlays
its own orange microphone badge on top of a recording app's menu bar icon,
which can stop forwarding clicks to the app underneath. Both were observed
live during development. The Dock icon isn't subject to either: it's always
there, always clickable, and clicking it (or double-clicking the app) opens
the notes window if none is open.

### ⌃⌥⌘R — start/stop from anywhere, no click needed

**⌃⌥⌘R (Control+Option+Command+R) toggles recording** regardless of what's
visible on screen, with a notification confirming start/stop either way —
useful when both the menu bar and Dock happen to be out of reach (e.g. a
fullscreen app in another Space).

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

1. **Run it** (`sabia` in a terminal, the LaunchAgent, or `Sabia.app`).
2. **Start recording** via the menu bar icon, the Dock icon (left- or
   right-click), the notes window's record button, ⌃⌥⌘R, or — in Chrome —
   just accept the automatic meeting prompt (see below). First use prompts
   for microphone and System Audio Recording permissions. While recording,
   the Dock icon badges and the notes window shows a live elapsed counter.
3. **Stop** the same way. Transcription starts automatically; a notification
   fires when it's ready, and the session appears in the notes window.

Each session lands in `~/Recordings/`, in a folder named for when it
happened (e.g. `2026-08-01 21h50`) and nothing else — no meeting name, no
generated ID. Inside, only two files are meant to be opened directly:

| File | Contents |
|---|---|
| `audio.m4a` | both tracks mixed into one ordinary, playable file |
| `transcript.md` | the transcript, speaker-tagged and timestamped |

Everything else in the folder is dot-prefixed (hidden in Finder by
default) — internal bookkeeping the app needs but a user doesn't:
`.mic.caf`/`.system.caf` (the raw per-track recordings, kept for
re-transcription), `.meta.json` (timestamps/offsets), `.transcript.json`
(the machine-readable transcript), `.transcribe.log`. Two raw tracks on
purpose under the hood: speech models do better on clean single-source
audio, and mic-vs-system is free two-party diarization — `me` vs `them`
with no speaker-identification model (see the Gotchas section below for
where this breaks down). CAF on purpose for the raw tracks: unlike m4a, it
needs no finalization pass — if the process dies mid-meeting, everything
already written is still readable; `audio.m4a` is produced afterward, once,
during transcription (see AudioMixer).

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
- **AVFoundation composition/export** — mixing the two raw tracks down into
  `audio.m4a` (see `AudioMixer.swift`)
- **WhisperKit / Whisper large-v3-turbo** — on-device Core ML transcription (default, multilingual)
- **FluidAudio / Parakeet** — on-device Core ML transcription (opt-in, English-only)
- **NSStatusItem** — the menu bar icon
- **SwiftUI (`NSHostingView`) + AppKit** — the notes window (session list +
  transcript reader + record button), hosted in a plain `NSWindow`
- **AppleScript / osascript** — polling Chrome's tabs for meeting URLs
  (`MeetingDetector.swift`); also how transcript-ready notifications are shown

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- **Diarization breaks down without headphones on the "them" side.** The
  mic/system split only gives clean two-party separation when your mic
  *only* hears you — on speakers (not headphones), audio playing out loud
  bleeds acoustically back into the mic, so both tracks capture nearly the
  same thing and get transcribed twice, once tagged "me" and once "them".
  Real two-person calls over headphones aren't affected; testing sabia by
  playing a video/song out loud instead of an actual call will show this.
  Fix: use headphones, or set `mic_voice_processing: true` in config.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to sabia itself when running as a LaunchAgent.

## Relationship to upstream

This is a fork, not a drop-in replacement — the binary, bundle identifier
(`com.gabrieImoreira.sabia`), config path, and default engine all diverge from
quill so the two can coexist on the same machine. Recording/capture code is
unchanged from upstream; the divergence is entirely in the transcription
layer and naming. MIT license, same as upstream (see `LICENSE`).
