import Foundation
import FluidAudio

/// Real speaker attribution for the system track.
///
/// Today the coordinator labels by track: `mic → "me"`, `system → "them"`.
/// The mic side is free ground truth and stays that way. The system side
/// collapses every remote participant into one label — in a five-person
/// meeting that's most of the value of a transcript gone, because you can no
/// longer tell who asked for what.
///
/// FluidAudio (already a dependency, for Parakeet) ships pyannote
/// community-1 + VBx clustering, so this is no new dependency.
///
/// Deliberately no name registry / rename UI yet — this is speaker
/// *separation* only (S1, S2, ...), not speaker *identification* across
/// meetings. That's a follow-up once separation itself is validated on a
/// real recording.
///
/// Caveats verified against FluidAudio 0.15.5 source, all of which shape the
/// code below:
///  - `.noSpeechDetected` is thrown, not returned, for silent input.
///  - `TimedSpeakerSegment.embedding` is the *cluster centroid*, repeated on
///    every segment of that speaker — not a per-span embedding (matters if a
///    later name registry is built from this).
///  - `qualityScore` is mean frame activation clamped to 0…1, not calibrated
///    confidence. Rank with it, don't treat it as a probability.
actor DiarizationEngine {
    struct SpeakerSpan {
        let speakerId: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Bounds for the number of remote speakers. A work meeting realistically
    /// has 1–8 voices on the far end; leaving it unbounded lets VBx split one
    /// person with variable mic conditions into several.
    private let speakerRange: ClosedRange<Int>
    /// FluidAudio's own default (`Clustering.community`). Confirmed live on a
    /// real 5-person work meeting with overlapping speech that the default
    /// under-segments (2 clusters for ~5 real voices) — that's a known VBx
    /// clustering limitation, not something to fight blind. Lowering it to
    /// 0.55, expecting more willingness to split, did the opposite: 1 cluster
    /// instead of 2. This isn't simple agglomerative distance clustering
    /// (VBx/PLDA), so the naive "lower threshold = more speakers" intuition
    /// doesn't hold here — left at the library default rather than guessing
    /// again without a real multi-speaker reference to tune against.
    private let clusteringThreshold: Double
    private var manager: OfflineDiarizerManager?

    init(speakerRange: ClosedRange<Int> = 1...8, clusteringThreshold: Double = 0.6) {
        self.speakerRange = speakerRange
        self.clusteringThreshold = clusteringThreshold
    }

    func prepare() async throws {
        guard manager == nil else { return }
        var config = OfflineDiarizerConfig()
            .withSpeakers(min: speakerRange.lowerBound, max: speakerRange.upperBound)
        config.clustering.threshold = clusteringThreshold
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        self.manager = manager
    }

    func release() {
        manager = nil
    }

    /// - Parameter samples: 16 kHz mono.
    ///   Returns `nil` when there is nothing to diarize (silent track, or no
    ///   speech detected), so the caller can fall back to a single label
    ///   rather than failing the session.
    func diarize(samples: [Float]) async throws -> [SpeakerSpan]? {
        guard let manager else { return nil }

        let result: DiarizationResult
        do {
            result = try await manager.process(audio: samples)
        } catch OfflineDiarizationError.noSpeechDetected {
            return nil
        }

        guard !result.segments.isEmpty else { return nil }
        return result.segments.map {
            SpeakerSpan(
                speakerId: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds)
            )
        }
    }

    /// Label a transcript segment by **maximum temporal overlap**, not by its
    /// start point: a spoken sentence routinely straddles a diarization
    /// boundary, and start-point matching mislabels exactly the turn-taking
    /// moments that matter most.
    nonisolated static func speaker(
        forSegmentFrom start: TimeInterval,
        to end: TimeInterval,
        in spans: [SpeakerSpan]
    ) -> String? {
        var best: (id: String, overlap: TimeInterval)?
        for span in spans {
            let overlap = min(end, span.end) - max(start, span.start)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap {
                best = (span.speakerId, overlap)
            }
        }
        return best?.id
    }
}
