import Foundation

/// Regenerates `.title` (see TitleEngine) for an already-transcribed
/// session — triggered from the notes window's resumo/ata "regenerate"
/// button, which reasonably expects the meeting's name to refresh too, not
/// just the document. Note: this overwrites a title the user renamed by
/// hand, same as any other regeneration — there's no separate "was this
/// auto-generated or user-edited" flag to preserve one over the other.
enum TitleOnDemand {
    static func regenerate(for dir: URL) async throws -> String {
        guard let dto = TranscriptDTO.load(from: dir.appendingPathComponent(TranscriptionCoordinator.transcriptJSONFileName))
        else { throw SummaryOnDemand.GenerationError.noTranscript }
        guard let apiKey = Config.openaiApiKey() else { throw SummaryOnDemand.GenerationError.missingAPIKey }

        let simplified = dto.segments.map { (speaker: $0.speaker, text: $0.text) }
        let title = try await TitleEngine.generate(
            segments: simplified,
            root: dir.deletingLastPathComponent(),
            excluding: dir,
            apiKey: apiKey,
            model: Config.llmModel()
        )
        try title.write(to: dir.appendingPathComponent(TitleEngine.titleFileName), atomically: true, encoding: .utf8)
        return title
    }
}
