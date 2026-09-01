# OpenAI summary/title, ata + resumo por tópico, and update/meeting popups

Status: approved (design). Date: 2026-09-01.

## Context

Coruja's optional LLM pass (summary + action items + title) runs entirely
against a local Ollama model today (`SummaryEngine`, `TitleEngine`,
`Config.llmPassEnabled/llmModel/llmEndpoint`). It is being discontinued in
favor of the OpenAI API, which also lets the user choose between two output
shapes instead of one fixed "short summary" format.

Separately, the app has no update mechanism — it's distributed as a zip on
GitHub Releases, and every install requires the user to manually run
`xattr -cr` on the downloaded `.app`. This adds an automatic update check
with a native, notification-style popup, plus a manual "check for updates"
entry in Settings.

Finally, the existing `MeetingPromptWindow` (used for "record this meeting?"
and "stop recording?") gets a visual pass to look more native/Apple-like,
and the "meeting ended" case additionally brings the app to the foreground
before prompting.

## Part 1 — OpenAI: API key storage

New file `Sources/coruja/OpenAIKeychain.swift`, using `Security.framework`
directly (no new SPM dependency):

- `get() -> String?`
- `set(_ key: String) throws`
- `delete()`

Stored as a generic password item, service `com.gabrieImoreira.coruja`,
account `openai_api_key`. The key never touches `config.json` or any log —
only the Settings UI reads/writes it, through this type.

`Config.llmPassEnabled()` keeps its existing meaning (does the opt-in pass
run at all) but no longer implies Ollama; whether it can actually run also
depends on a key being present in the Keychain (checked by the caller,
`TranscriptionCoordinator`, not baked into `Config`).

## Part 2 — OpenAI: config shape

`Config.swift` changes:

- Remove: `transcription.llm_endpoint` (Ollama-only, no OpenAI equivalent
  worth keeping — the endpoint is always `api.openai.com`).
- Keep: `transcription.llm_pass` (bool, opt-in toggle), `transcription.llm_model`
  (now an OpenAI model tag, default `"gpt-4o-mini"` instead of
  `"llama3.1:8b"`).
- Add: `transcription.summary_type`, one of `"ata"` | `"topicos"`, default
  `"topicos"`.
- `Config.save(...)` gains a `summaryType` parameter alongside the existing
  ones; no key needs hand-editing-only status here (unlike `on_stop` /
  `llm_endpoint` today), since both fields have Settings UI.

## Part 3 — OpenAI: SummaryEngine and TitleEngine

Both engines keep their existing internal shape (map-reduce over ~10min
chunks for `SummaryEngine`; TF-IDF keyword extraction + one short LLM call
for `TitleEngine`) — only the transport and prompts change.

**Transport**: `POST https://api.openai.com/v1/chat/completions`,
`Authorization: Bearer <key>`, `response_format: {"type": "json_object"}`
for `SummaryEngine` (structured output), plain text response for
`TitleEngine`'s title call. Same non-negotiable extraction rules from the
current Ollama prompts carry over verbatim (no invented content, no
grammar cleanup, no action item without an explicit commitment) — the
provider changes, the "don't hallucinate" contract doesn't.

**Two prompts/schemas for `SummaryEngine`**, selected by
`Config.summaryType()`:

- `topicos` (detailed topic-by-topic summary): replaces today's "1 to 3
  generic sentences per chunk" with a list of topics discussed in that
  chunk, each with 2-4 grounded sentences. The reduce step merges topics
  across chunks (same topic discussed in two chunks gets combined, not
  duplicated) instead of concatenating prose paragraphs.
- `ata` (formal minutes): structured sections — pauta (topics covered),
  decisões tomadas, itens de ação. No participant list (speaker labels are
  "me" / diarization tags, not real names, so a participant section would
  either be empty or wrong).

Both schemas keep `itens_de_acao` (same `ActionItem` struct) — it's
orthogonal to which narrative format wraps around it.

**Errors**: `SummaryError`/`TitleError` cases change from
"Ollama returned HTTP X — is it running?" to OpenAI-shaped failures: missing
key (checked before the call, not an HTTP error), 401 (invalid key), 429
(rate limit), and the existing "unparseable JSON" case unchanged.

## Part 4 — Rendering

`TranscriptionCoordinator.renderedSummary` still writes `summary.md`, with
its Markdown shape depending on which type produced the `Summary` — the
`ata` shape gets its own heading structure ("## Pauta", "## Decisões",
"## Itens de ação") instead of reusing the "## Resumo" / "## Itens de ação"
layout used for `topicos`.

## Part 5 — Settings UI

`SettingsRootView`'s "Resumo e título automático" section is replaced:

- `SecureField` for pasting the API key + "Salvar" button, writing through
  `OpenAIKeychain`. Never re-displays a saved key — shows a status line
  ("chave configurada" / "nenhuma chave configurada").
- Explicit privacy note under the toggle: transcript content leaves the
  machine to OpenAI when this is on — stated plainly, not buried.
- Picker: "Ata" vs "Resumo detalhado por tópico" (`summary_type`).
- Text field for the model tag (default `gpt-4o-mini`), same pattern as
  today's model field.
- Remove `ollamaStatusRow` / `probeOllama` entirely — no live "is the
  server up" check makes sense for a hosted API the same way (an API key
  is either present or not; no local "not running" state to poll for).

## Part 6 — Update checker

New file `Sources/coruja/UpdateChecker.swift`:

- `checkForUpdate() async -> UpdateInfo?` calls
  `GET https://api.github.com/repos/gabrieImoreira/coruja/releases/latest`
  (no auth — public API, 60 req/h per IP is generous for 1x/day), reads
  `tag_name` and the `.zip` asset's `browser_download_url`.
- Compares against `CFBundleShortVersionString` with a small semver parser
  (major.minor.patch, no external dependency).
- Returns `UpdateInfo(version, zipURL, releaseNotesURL)` when the remote
  version is greater; `nil` otherwise (including on any network/parse
  failure — a failed check is silent, never an error popup, for the
  automatic path; the manual Settings button surfaces failures instead).

**Dismissal**: `UserDefaults` key `corujaDismissedUpdateVersion` records the
last version the user dismissed from the *automatic* popup. The automatic
check won't re-prompt for that version or older. The manual "Verificar
atualizações" button in Settings always checks live and ignores this value.

**Scheduling**: `Coruja.swift`'s app controller checks once at launch (after
the existing transcription warm-up) and every 24h thereafter via a
`Timer`, for as long as the process runs — mirrors the existing
`meetingPollTimer` pattern.

**Install flow**, on "Atualizar":

1. Download the zip to `~/Library/Caches/coruja/update.zip`.
2. Unzip via `ditto -x -k` (same tool the build script already uses to zip).
3. Validate the extracted `.app` has a readable `Info.plist`.
4. Remove the quarantine attribute (`xattr -cr`) — this is what lets the
   new copy open without the manual Terminal step the README documents
   today.
5. Move the currently-installed `/Applications/Coruja.app` to the Trash
   (not delete outright — recoverable if anything above was wrong).
6. Move the new `.app` into `/Applications`, launch it via
   `NSWorkspace.shared.openApplication`, then `NSApp.terminate` the running
   process.

Any failure in steps 1-4 leaves the currently-running app untouched and
shows an error popup (reusing the same visual component from Part 8) —
never reaches step 5 on a failure.

## Part 7 — Settings: manual check + About section

New "Sobre" section in `SettingsRootView`: current version
(`CFBundleShortVersionString`) + "Verificar atualizações" button. Runs
`checkForUpdate()` ignoring `corujaDismissedUpdateVersion`; shows either
"Você já está na versão mais recente" or the same update popup as the
automatic path.

## Part 8 — Shared popup component (visual redesign)

Replaces `MeetingPromptWindow` with a restyled non-activating `NSPanel`,
reused for all three notification-style popups (meeting detected, meeting
ended, update available):

- `NSVisualEffectView` background (`.hudWindow` material, vibrancy), rounded
  corners (`continuous`, ~14pt radius), subtle shadow — reads as a native
  macOS notification rather than a plain dialog box.
- SF Symbol icon on the left (context-dependent), bold title + secondary-gray
  body text, matching the app's existing monochrome palette (no system blue
  accent on buttons — same restrained style as `Theme.swift`'s rest of the
  UI).
- Auto-dismiss (25s, existing behavior) stays for the two meeting prompts;
  the update popup does **not** auto-dismiss — a decision this consequential
  shouldn't disappear unattended.

**Positioning, per case:**

- *Meeting detected* ("Gravar com a coruja?"): top-right of the screen —
  unchanged from today, new skin only.
- *Meeting ended* ("Parar a gravação?"): before showing, calls
  `NSApp.activate(ignoringOtherApps: true)` and brings the notes window to
  front (opening it if closed), then positions the popup at the top-right
  of that window's frame (not the screen).
- *Update available*: bottom-right of the screen, unprompted — no window
  needs to be in focus for it to appear.

The existing guard against re-prompting while already recording
(`handleMeetingDetected`'s `guard session == nil`) is unchanged — confirmed
already correct during design, not a bug.

## Testing

- `SummaryEngine`/`TitleEngine`: unit-test prompt construction and JSON
  decoding against fixed mock HTTP responses (no live OpenAI calls in CI).
- `UpdateChecker`: unit-test the semver comparison and the dismissed-version
  gate against mock release payloads.
- Popup component and install flow: manual verification (documented in the
  implementation plan) — no automated UI test harness exists in this
  project today, consistent with how `MeetingPromptWindow` and the rest of
  the AppKit UI are verified currently.
