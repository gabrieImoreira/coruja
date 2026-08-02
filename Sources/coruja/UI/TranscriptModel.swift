import Foundation

/// Mirrors TranscriptionCoordinator's private `Transcript`/`Segment` JSON
/// schema, read back from `.transcript.json` for the notes window's
/// per-segment rendering (transcript.md is plain text, fine for copying but
/// not for laying out speaker-tagged rows).
struct TranscriptDTO: Codable {
    struct Segment: Codable, Identifiable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
        var id: Int { start_ms }
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    static func load(from url: URL) -> TranscriptDTO? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptDTO.self, from: data)
    }
}
