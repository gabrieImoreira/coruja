import Foundation

/// Optional user config at ~/.config/coruja/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    /// `var`, not `let` — ConfigTests points this at a temp file so tests
    /// never read or write the developer's real ~/.config/coruja/config.json.
    static var path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/coruja/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = recordingsDirRaw(), !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Unexpanded `recordings_dir` string as stored (e.g. `"~/Recordings"`),
    /// for the Settings UI's text field — `recordingsDir()` expands `~` for
    /// actual filesystem use, which isn't what you want to show or re-edit.
    static func recordingsDirRaw() -> String? {
        load()?["recordings_dir"] as? String
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name: "whisper" (multilingual, WhisperKit — coruja's
    /// default, since the whole point of this fork is pt-BR) or "parakeet"
    /// (English-only, FluidAudio, kept for parity with upstream quill). The
    /// coordinator warns and falls back to whisper for anything unrecognized.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "whisper"
    }

    /// ISO-639-1 language code passed to the whisper engine's decoder (e.g.
    /// "pt"). `nil` (or the literal "auto") lets Whisper detect it per
    /// segment — useful for mixed-language meetings. Ignored by parakeet,
    /// which is English-only.
    static func transcriptionLanguage() -> String? {
        guard let lang = transcription()?["language"] as? String, !lang.isEmpty else { return "pt" }
        return lang == "auto" ? nil : lang
    }

    /// Raw stored language code, including the literal "auto" — unlike
    /// `transcriptionLanguage()`, which collapses "auto" to `nil` for the
    /// engine. The Settings UI needs the raw value to pre-select the right
    /// picker option.
    static func transcriptionLanguageCode() -> String {
        transcription()?["language"] as? String ?? "pt"
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Optional OpenAI pass over the finished transcript (summary + action
    /// items + title). Off by default — unlike everything else this app
    /// does, its output is *generated* text rather than a direct
    /// transcription, and turning it on sends the transcript to OpenAI —
    /// the one place this app's "nothing leaves the machine" design doesn't
    /// hold. Never turns on without the user asking, and the Settings UI
    /// says so explicitly next to the toggle.
    static func llmPassEnabled() -> Bool {
        transcription()?["llm_pass"] as? Bool ?? false
    }

    /// OpenAI model tag (e.g. "gpt-5.6-terra"). Needs a valid API key (see
    /// `openaiApiKey()`) — this alone doesn't enable the pass.
    static func llmModel() -> String {
        transcription()?["llm_model"] as? String ?? "gpt-5.6-terra"
    }

    /// OpenAI API key, stored in plain text like every other setting here —
    /// NOT in the macOS Keychain. Ad-hoc code signing (no paid Apple Developer
    /// certificate, see README) means Keychain access control ties to a code
    /// signature that changes on every self-update, which would otherwise
    /// re-prompt the user for Keychain permission on every single update.
    static func openaiApiKey() -> String? {
        let key = transcription()?["openai_api_key"] as? String
        return (key?.isEmpty ?? true) ? nil : key
    }

    /// Which document shape the summary pass produces: "ata" (formal
    /// minutes — pauta/decisões) or "topicos" (detailed topic-by-topic
    /// narrative). See SummaryEngine.SummaryType.
    static func summaryType() -> String {
        transcription()?["summary_type"] as? String ?? "topicos"
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Overwrites every key the Settings UI knows about, preserving anything
    /// else already in the file (`on_stop` — a power-user key with no UI,
    /// only ever set by hand). Called with a full snapshot of the UI's state
    /// on every change, not incrementally, since that's simpler than
    /// per-field patch methods and this file is tiny.
    static func save(
        recordingsDir: String,
        transcriptionEnabled: Bool,
        transcriptionEngine: String,
        transcriptionLanguage: String,
        llmPassEnabled: Bool,
        openaiApiKey: String,
        llmModel: String,
        summaryType: String,
        micVoiceProcessing: Bool
    ) {
        var json = load() ?? [:]

        let trimmedDir = recordingsDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDir.isEmpty {
            json.removeValue(forKey: "recordings_dir")
        } else {
            json["recordings_dir"] = trimmedDir
        }
        json["mic_voice_processing"] = micVoiceProcessing

        var t = json["transcription"] as? [String: Any] ?? [:]
        let trimmedKey = openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            t.removeValue(forKey: "openai_api_key")
        } else {
            t["openai_api_key"] = trimmedKey
        }
        t["enabled"] = transcriptionEnabled
        t["engine"] = transcriptionEngine
        t["language"] = transcriptionLanguage
        t["llm_pass"] = llmPassEnabled
        let trimmedModel = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        t["llm_model"] = trimmedModel.isEmpty ? "gpt-5.6-terra" : trimmedModel
        t["summary_type"] = summaryType == "ata" ? "ata" : "topicos"
        t.removeValue(forKey: "llm_endpoint") // orphaned key from the removed Ollama config
        json["transcription"] = t

        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
