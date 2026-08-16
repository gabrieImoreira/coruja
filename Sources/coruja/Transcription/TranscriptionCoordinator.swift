import AVFoundation
import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// .mic.caf → "me", .system.caf → "them"; each track's segments are shifted
/// by its start offset, merged by timestamp, and written as .transcript.json
/// (canonical, hidden) plus transcript.md (readable, visible). The two raw
/// tracks are also mixed down into audio.m4a — the one audio file a user is
/// meant to see; see AudioMixer. The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's
/// .transcribe.log and never block later jobs.
actor TranscriptionCoordinator {
    static let transcriptJSONFileName = ".transcript.json"
    static let transcriptMDFileName = "transcript.md"
    static let summaryMDFileName = "summary.md"
    static let audioFileName = "audio.m4a"
    static let logFileName = ".transcribe.log"

    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    /// Set while a prepare() is in flight, so a concurrent caller (warmUp()
    /// racing an actual transcription — both can call preparedEngine()
    /// before either finishes, since actor reentrancy lets them interleave
    /// at the `await engine.prepare()` suspension point) awaits the same
    /// load instead of constructing and loading a second engine instance.
    private var preparingTask: Task<TranscriptionEngine, Error>?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    /// Speaker separation for the "them" (system audio) track only — the mic
    /// side is already ground truth per-track, one person. Lazily prepared on
    /// first use, same pattern as the transcription engine; not part of
    /// warmUp() since it's a smaller, separate model cost.
    private var diarizer: DiarizationEngine?
    private var diarizerPreparingTask: Task<DiarizationEngine, Error>?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Loads the transcription engine right away instead of waiting for the
    /// first real transcription — Core ML's one-time per-launch model
    /// specialization takes on the order of a couple minutes (confirmed
    /// live). Warming it at app launch means that cost lands quietly in the
    /// background instead of stalling the first meeting's transcript.
    func warmUp() {
        guard Config.transcriptionEnabled() else { return }
        Task { _ = try? await preparedEngine() }
    }

    /// Scan the recordings root for sessions that finished (.meta.json
    /// exists) but were never transcribed. Folder names sort chronologically,
    /// so oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent(RecordingSession.metaFileName).path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent(Self.transcriptJSONFileName).path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                notifyUser(title: "Transcrição pronta", body: dir.lastPathComponent)
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(title: "Não foi possível transcrever", body: dir.lastPathComponent)
            }
        }
        // Deliberately not releasing the engine here anymore: reloading it
        // costs on the order of minutes (Core ML's one-time per-launch model
        // specialization, confirmed live), so a menu-bar app used for
        // several meetings across a day should pay that cost once via
        // warmUp(), not before every single recording. ~1.5GB held for the
        // life of the process is the trade.
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        do {
            try await AudioMixer.mixDown(
                tracks: meta.tracks.map { (dir.appendingPathComponent($0.file), $0.offsetMs) },
                to: dir.appendingPathComponent(Self.audioFileName)
            )
        } catch {
            // The friendly audio.m4a is a nice-to-have, not the transcript —
            // don't fail the whole session over a mixdown error.
            log(dir, "audio mixdown failed: \(error)")
        }

        var merged: [Transcript.Segment] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            // Whisper's chunking can stop short of the true end of a track
            // on quiet/unclear audio without raising any error (observed
            // live: ~25s of audible speech silently dropped from a ~6.5min
            // recording). Flag it loudly here since nothing else will.
            if let file = try? AVAudioFile(forReading: audio),
               file.processingFormat.sampleRate > 0,
               let lastEnd = segments.map(\.end).max()
            {
                let audioDuration = Double(file.length) / file.processingFormat.sampleRate
                if audioDuration - lastEnd > 10 {
                    log(dir, "warning: \(track.file) is \(Int(audioDuration))s but transcript stops at \(Int(lastEnd))s — possible dropped tail")
                }
            }
            // Speaker separation only on the remote side — the mic track is
            // already ground truth for "me", one person, nothing to separate.
            var spans: [DiarizationEngine.SpeakerSpan]?
            if track.speaker == "them" {
                do {
                    let diarizer = try await preparedDiarizer()
                    let samples = try AudioPrep.load(audio)
                    spans = try await diarizer.diarize(samples: samples)
                    if let spans {
                        let distinct = Set(spans.map(\.speakerId)).count
                        log(dir, "\(track.file): \(distinct) speaker(s) separated")
                    } else {
                        log(dir, "\(track.file): no speech to diarize — labeling as \"outro\"")
                    }
                } catch {
                    // Diarization is an enhancement, not the transcript itself —
                    // a failure here shouldn't cost the session its text.
                    log(dir, "diarization failed for \(track.file): \(error) — labeling as \"outro\"")
                }
            }

            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map { segment in
                let speaker: String
                if let spans, let id = DiarizationEngine.speaker(
                    forSegmentFrom: segment.start, to: segment.end, in: spans
                ) {
                    speaker = id
                } else if track.speaker == "them" {
                    speaker = "outro"
                } else {
                    speaker = track.speaker
                }
                return Transcript.Segment(
                    speaker: speaker,
                    start_ms: Int((segment.start + offset) * 1000),
                    end_ms: Int((segment.end + offset) * 1000),
                    text: segment.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")

        if Config.llmPassEnabled() {
            await runSummary(for: merged, in: dir)
        }
    }

    /// Opt-in local-LLM pass (see Config.llmPassEnabled / SummaryEngine).
    /// A failure here (Ollama not running, model not pulled, bad JSON back)
    /// is logged and otherwise ignored — the transcript is already written
    /// and is the thing that matters; the summary is a bonus.
    private func runSummary(for segments: [Transcript.Segment], in dir: URL) async {
        let timed = segments.map {
            SummaryEngine.TimedSegment(speaker: $0.speaker, text: $0.text, startMs: $0.start_ms)
        }
        do {
            let summary = try await SummaryEngine.summarize(
                segments: timed,
                model: Config.llmModel(),
                endpoint: Config.llmEndpoint()
            )
            try Self.renderedSummary(summary).write(
                to: dir.appendingPathComponent(Self.summaryMDFileName),
                atomically: true, encoding: .utf8
            )
            log(dir, "summary written — \(summary.itensDeAcao.count) action item(s)")
        } catch {
            log(dir, "summary skipped: \(error)")
        }
    }

    private static func renderedSummary(_ summary: SummaryEngine.Summary) -> String {
        var lines = ["## Resumo", "", summary.resumo, ""]
        if !summary.itensDeAcao.isEmpty {
            lines.append("## Itens de ação")
            lines.append("")
            for item in summary.itensDeAcao {
                var line = "- \(item.item)"
                if let responsavel = item.responsavel { line += " — **\(responsavel)**" }
                if let prazo = item.prazo { line += " (prazo: \(prazo))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        if let preparingTask { return try await preparingTask.value }

        let configured = Config.transcriptionEngine()
        let newEngine: TranscriptionEngine
        switch configured {
        case "parakeet":
            newEngine = ParakeetEngine()
        case "whisper":
            newEngine = WhisperEngine(language: Config.transcriptionLanguage())
        default:
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using whisper\n".utf8
            ))
            newEngine = WhisperEngine(language: Config.transcriptionLanguage())
        }

        let task = Task<TranscriptionEngine, Error> {
            try await newEngine.prepare()
            return newEngine
        }
        preparingTask = task
        defer { preparingTask = nil }
        let prepared = try await task.value
        self.engine = prepared
        return prepared
    }

    private func preparedDiarizer() async throws -> DiarizationEngine {
        if let diarizer { return diarizer }
        if let diarizerPreparingTask { return try await diarizerPreparingTask.value }

        let task = Task<DiarizationEngine, Error> {
            let newDiarizer = DiarizationEngine()
            try await newDiarizer.prepare()
            return newDiarizer
        }
        diarizerPreparingTask = task
        defer { diarizerPreparingTask = nil }
        let prepared = try await task.value
        self.diarizer = prepared
        return prepared
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent(Self.logFileName)
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent(RecordingSession.metaFileName)
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
private struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Write .transcript.json (hidden, canonical) and transcript.md (visible,
    /// readable). Both writes are atomic (temp file + rename), so a partially
    /// written transcript never exists on disk — resumePending treats
    /// presence of .transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent(TranscriptionCoordinator.transcriptJSONFileName), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent(TranscriptionCoordinator.transcriptMDFileName), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
