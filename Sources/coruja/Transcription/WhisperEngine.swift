import AVFoundation
import Foundation
import WhisperKit

/// Whisper via WhisperKit's Core ML port (Argmax). Multilingual — unlike
/// Parakeet, this is the engine coruja uses for Portuguese (and any other
/// language Whisper covers). Models (~600 MB - 1.5 GB depending on variant)
/// download once into WhisperKit's managed cache; after that, transcription
/// runs entirely on-device.
///
/// Deliberately still one `transcribe(audioArray:)` call per track, not one
/// call per VAD-detected speech window. An earlier version of this file did
/// external VAD windowing and called WhisperKit once per window — confirmed
/// live that this reproduces a WhisperKit 0.18.0 bug on nearly every window
/// of a real recording: the forced token prefix before any real content
/// (language/task/timestamp tokens) is evaluated by the same early-exit check
/// as real content, so if the model's next prediction right after that prefix
/// happens to be end-of-text, the call returns empty — no error, and because
/// avgLogprob 0.0 isn't "below" the threshold, the temperature-fallback loop
/// treats it as a trivially complete success and never retries. A single
/// continuous call over the whole track only pays that forced-prefix risk
/// once, not once per window, and is the architecture this file already
/// shipped with successfully. See argmaxinc/argmax-oss-swift#372 (open,
/// unmerged fix, and scoped only to the `promptTokens` case — this project
/// doesn't use promptTokens and still hit the same class of bug via manual
/// windowing).
actor WhisperEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL, Error?)

        var description: String {
            switch self {
            case .notPrepared: return "whisper engine used before prepare()"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            }
        }
    }

    nonisolated let name = "whisper"
    nonisolated let model: String
    private let language: String?
    private let modelVariant: String

    private var pipe: WhisperKit?
    private var wordTimestampsAvailable = false

    /// The coordinator writes per-session diagnostics into `.transcribe.log`;
    /// this lets the engine contribute to that log instead of stderr. Set it
    /// right before each `transcribe(_:)` call.
    private var logHandler: (@Sendable (String) -> Void)?

    func setLogHandler(_ handler: (@Sendable (String) -> Void)?) {
        logHandler = handler
    }

    private func log(_ message: String) {
        if let logHandler {
            logHandler(message)
        } else {
            FileHandle.standardError.write(Data("whisper: \(message)\n".utf8))
        }
    }

    /// - Parameters:
    ///   - language: ISO-639-1 code passed to WhisperKit's decoder (e.g. "pt"
    ///     for Portuguese). `nil` lets Whisper auto-detect per segment.
    ///   - modelVariant: WhisperKit model name. Turbo (4 decoder layers vs 32):
    ///     confirmed live that the non-turbo variant takes well over 2x as
    ///     long on a real 87min meeting. Most of the accuracy win already
    ///     came from the hallucination filter + gain-normalization fix on
    ///     turbo itself (WER 26.3% -> 14.8%, no model change) — fast
    ///     turnaround right after a meeting ends matters more here than
    ///     the additional accuracy non-turbo gets, so this stays turbo.
    init(language: String? = "pt", modelVariant: String = "large-v3-v20240930_turbo") {
        self.language = language
        self.modelVariant = modelVariant
        self.model = "whisperkit-\(modelVariant)"
    }

    func prepare() async throws {
        guard pipe == nil else { return }
        // `load: true` so `textDecoder.supportsWordTimestamps` reflects the
        // real model state here (right after prepare) instead of `false` by
        // default and only becoming accurate after the first transcribe()
        // call lazily loads it — checked once, at prepare time, below.
        let bundled = Self.bundledModelFolder()
        let whisper = try await WhisperKit(WhisperKitConfig(
            model: modelVariant,
            modelFolder: bundled?.path,
            verbose: false,
            load: true
        ))
        pipe = whisper
        wordTimestampsAvailable = whisper.textDecoder.supportsWordTimestamps
        if !wordTimestampsAvailable {
            log("model \(modelVariant) has no alignment_heads_weights — "
                + "falling back to segment-level assembly")
        }
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let pipe else { throw EngineError.notPrepared }

        // An empty/unreadable track must not reach AVFoundation's resampler,
        // where it raises an uncatchable ObjC exception and takes the daemon
        // down with it.
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        let raw = try AudioPrep.load(audio)
        let (samples, stats) = AudioPrep.normalized(raw)
        log("\(audio.lastPathComponent) level: \(stats.description)")

        // A track with no measurable speech is the rca-001 silent-mic case.
        // Transcribing amplified noise here is how you get a page of "Obrigado".
        guard stats.speechLevel > 1e-5 else {
            log("\(audio.lastPathComponent): no measurable speech (silent track) — skipping")
            return []
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: wordTimestampsAvailable,
            // compressionRatioThreshold / logProbThreshold: real Whisper CLI
            // defaults. Safe to revert — confirmed these two never discard a
            // segment on their own, only decide whether to retry hotter, so
            // HallucinationFilter (below) is the only thing that actually
            // filters.
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            // firstTokenLogProbThreshold, unlike the two above, DOES reject a
            // whole segment outright — and its real default (-1.5) is exactly
            // what the original comment on this file described discarding
            // whole tracks on real room-mic audio for. Confirmed live: tightening
            // it back to -1.5 reproduced that — dozens of 20-40s gaps spread
            // across an 87min recording (missed-speech jumped from 6.7% to
            // 43% on the same file). Left nil: with the single-continuous-call
            // architecture this file already uses, WhisperKit's own seek loop
            // is what decides where a real window ends, so there's no benefit
            // to this check firing on ordinary quiet/casual speech.
            firstTokenLogProbThreshold: nil,
            noSpeechThreshold: nil, // dead code in 0.18.0 — noSpeechProb is hardcoded to 0
            chunkingStrategy: ChunkingStrategy.none
        )

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)

        var candidates: [HallucinationFilter.Candidate] = []
        var words: [SegmentAssembler.TimedWord] = []
        for (windowIndex, result) in results.enumerated() {
            for segment in result.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                candidates.append(HallucinationFilter.Candidate(
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    text: text,
                    avgLogprob: segment.avgLogprob,
                    temperature: segment.temperature,
                    windowIndex: windowIndex
                ))
                for w in segment.words ?? [] {
                    words.append(SegmentAssembler.TimedWord(
                        text: w.word,
                        start: TimeInterval(w.start),
                        end: TimeInterval(w.end),
                        probability: w.probability
                    ))
                }
            }
        }

        let (kept, report) = HallucinationFilter().apply(to: candidates)
        if !report.isEmpty {
            log("\(audio.lastPathComponent) \(report.description)")
        }

        let assembled: [SegmentAssembler.Assembled]
        if !words.isEmpty {
            // Only keep words inside surviving segments, so the filter's
            // decisions are not undone by reassembling from raw words.
            let survivingRanges = kept.map { ($0.start, $0.end) }
            let filtered = words.filter { word in
                survivingRanges.contains { word.start >= $0.0 - 0.05 && word.end <= $0.1 + 0.05 }
            }
            assembled = SegmentAssembler.assemble(words: filtered.isEmpty ? words : filtered)
        } else {
            assembled = SegmentAssembler.merge(
                segments: kept.map { ($0.start, $0.end, $0.text) }
            )
        }

        return assembled
            .sorted { $0.start < $1.start }
            .map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text) }
    }

    func release() async {
        pipe = nil
    }

    /// `Coruja.app/Contents/Resources/whisperkit-model`, if `scripts/build-app.sh`
    /// bundled the model there — resolves via `Bundle.main` so it only exists
    /// when actually running from the .app. Not present for a `swift build`
    /// dev run or a plain CLI install at `/usr/local/bin`, where WhisperKit
    /// falls back to its normal download-and-cache behavior (`modelFolder: nil`).
    private static func bundledModelFolder() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent("whisperkit-model", isDirectory: true)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
