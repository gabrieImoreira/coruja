import Foundation

/// Generates the OpenAI summary/ata for a session that either never got the
/// automatic pass (opted out at the time) or only got the *other* document
/// type — triggered from the notes window, not from TranscriptionCoordinator's
/// pipeline. Reads the already-written `.transcript.json` instead of taking
/// live segments, since this always runs well after transcription finished.
enum SummaryOnDemand {
    enum GenerationError: Error, CustomStringConvertible {
        case noTranscript
        case missingAPIKey

        var description: String {
            switch self {
            case .noTranscript: return "transcrição ainda não disponível para esta reunião"
            case .missingAPIKey: return "nenhuma chave da OpenAI configurada"
            }
        }
    }

    /// Generates `type`'s document for the session at `dir`, writes it to
    /// `TranscriptionCoordinator.summaryFileName(for: type)`, and returns the
    /// rendered Markdown so the caller can display it immediately without a
    /// second disk read.
    ///
    /// - Parameter focus: optional user-supplied topic to steer the pass
    ///   toward (see `SummaryEngine.summarize`'s `focus` parameter) — the
    ///   notes window's "regenerate" popover, nil for a plain (re)generation.
    static func generate(for dir: URL, type: SummaryEngine.SummaryType, focus: String? = nil) async throws -> String {
        guard let dto = TranscriptDTO.load(from: dir.appendingPathComponent(TranscriptionCoordinator.transcriptJSONFileName))
        else { throw GenerationError.noTranscript }
        guard let apiKey = Config.openaiApiKey() else { throw GenerationError.missingAPIKey }

        let timed = dto.segments.map {
            SummaryEngine.TimedSegment(speaker: $0.speaker, text: $0.text, startMs: $0.start_ms)
        }
        let summary = try await SummaryEngine.summarize(
            segments: timed,
            apiKey: apiKey,
            model: Config.llmModel(),
            summaryType: type,
            focus: focus
        )
        let rendered = SummaryEngine.render(summary, type: type)
        try rendered.write(
            to: dir.appendingPathComponent(TranscriptionCoordinator.summaryFileName(for: type)),
            atomically: true, encoding: .utf8
        )
        return rendered
    }
}
