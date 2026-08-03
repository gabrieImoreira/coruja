import Foundation

/// One timed span of recognized speech from a single track, relative to that
/// track's own start.
struct TranscriptSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// A speech-to-text engine coruja can run locally. `prepare()` is called
/// once at app launch (warmUp) rather than lazily on first use — Core ML's
/// one-time per-launch model specialization costs on the order of minutes,
/// confirmed live, so it's better paid quietly in the background than in
/// front of the first meeting's transcript. The engine then stays loaded
/// for the life of the process; `release()` exists for engine-switching
/// (e.g. config changes engine mid-run) rather than idle cleanup.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    func prepare() async throws
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment]
    func release() async
}
