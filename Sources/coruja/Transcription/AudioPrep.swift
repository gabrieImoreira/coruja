import AVFoundation
import Foundation
import WhisperKit

/// Gain normalization for a track before it reaches the decoder.
///
/// Deliberately does *not* do VAD-based windowing: an earlier version of this
/// pipeline split each track into VAD-detected speech windows and decoded
/// them as separate WhisperKit calls, which hit a confirmed WhisperKit 0.18.0
/// bug — the forced token prefix (language/task/timestamp) before real
/// content is evaluated by the same early-exit check as real content, so if
/// the model's next prediction right after that prefix happens to be
/// end-of-text, the window returns empty with no error. That bug fires on
/// nearly every isolated `transcribe(audioArray:)` call for real meeting
/// audio. A single continuous call over the whole track — what this file
/// still does — does not reproduce it anywhere near as often; WhisperKit's
/// own internal seek loop only pays the forced-prefix cost once per track,
/// not once per window. So: normalize gain, skip tracks with no measurable
/// speech, but hand the *whole* track to the decoder in one call.
enum AudioPrep {
    static let sampleRate = 16_000

    struct LevelStats {
        /// 90th percentile of frame RMS — a robust proxy for speech level.
        let speechLevel: Float
        /// 10th percentile of frame RMS — a robust proxy for the noise floor.
        let noiseFloor: Float
        /// Linear gain applied to reach the target level.
        let appliedGain: Float
        /// Peak after gain (always <= 0.99 — gain is capped to avoid clipping).
        let peakAfterGain: Float

        var estimatedSNRdB: Float {
            guard noiseFloor > 0, speechLevel > 0 else { return .infinity }
            return 20 * log10(speechLevel / noiseFloor)
        }

        var description: String {
            String(
                format: "speech %.1f dBFS, floor %.1f dBFS, SNR ~%.1f dB, gain %.2fx, peak %.2f",
                20 * log10(max(speechLevel, 1e-9)),
                20 * log10(max(noiseFloor, 1e-9)),
                estimatedSNRdB,
                appliedGain,
                peakAfterGain
            )
        }
    }

    enum PrepError: Error, CustomStringConvertible {
        case emptyAudio(URL)

        var description: String {
            switch self {
            case .emptyAudio(let url): return "no samples decoded from \(url.lastPathComponent)"
            }
        }
    }

    // MARK: - Load

    /// 16 kHz mono Float32, which is what Whisper wants. `.sumChannels(nil)`
    /// mixes every channel with peak normalization, so a multichannel tap
    /// track collapses correctly instead of losing all but one channel.
    static func load(_ url: URL) throws -> [Float] {
        let samples = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: url.path,
            channelMode: .sumChannels(nil)
        )
        guard !samples.isEmpty else { throw PrepError.emptyAudio(url) }
        return samples
    }

    // MARK: - Normalize

    /// Bring the track to `targetRMS` (default -20 dBFS) using the 90th
    /// percentile of frame RMS as the speech-level estimate.
    ///
    /// Percentile rather than overall RMS on purpose: a meeting track is mostly
    /// silence, so overall RMS tracks the *silence* level and a quiet speaker
    /// would get boosted into clipping. p90 tracks the speech.
    ///
    /// Gain is capped by the track's true peak so the result never clips —
    /// confirmed live that clamping samples *after* applying an uncapped gain
    /// (the original approach) hard-clips loud syllables into a flat square
    /// wave across a meaningful fraction of a real recording.
    static func normalized(
        _ samples: [Float],
        targetRMS: Float = 0.1,
        gainRange: ClosedRange<Float> = 0.25...40.0
    ) -> (samples: [Float], stats: LevelStats) {
        let energies = frameRMS(samples)
        guard !energies.isEmpty else {
            return (samples, LevelStats(speechLevel: 0, noiseFloor: 0, appliedGain: 1, peakAfterGain: 0))
        }

        let sorted = energies.sorted()
        let speechLevel = percentile(sorted, 0.90)
        let noiseFloor = percentile(sorted, 0.10)

        // A track with no measurable speech (mic died: rca-001 saw -91 dB) must
        // not be boosted 40x into pure amplified noise — the decoder would
        // happily hallucinate over it. Leave it alone and let the caller see
        // the stats and skip it.
        guard speechLevel > 1e-5 else {
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            return (samples, LevelStats(
                speechLevel: speechLevel, noiseFloor: noiseFloor,
                appliedGain: 1, peakAfterGain: peak
            ))
        }

        let rawGain = targetRMS / speechLevel
        let truePeak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let maxGainForNoClip = truePeak > 0 ? 0.99 / truePeak : gainRange.upperBound
        let gain = min(max(rawGain, gainRange.lowerBound), gainRange.upperBound, maxGainForNoClip)

        var out = samples
        var peak: Float = 0
        for i in out.indices {
            let v = out[i] * gain
            peak = max(peak, abs(v))
            out[i] = v
        }

        return (out, LevelStats(
            speechLevel: speechLevel, noiseFloor: noiseFloor,
            appliedGain: gain, peakAfterGain: peak
        ))
    }

    private static func frameRMS(_ samples: [Float], frameLength: Int = 320) -> [Float] {
        guard samples.count >= frameLength else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / frameLength)
        var i = 0
        while i + frameLength <= samples.count {
            var sum: Float = 0
            for j in i..<(i + frameLength) { sum += samples[j] * samples[j] }
            out.append((sum / Float(frameLength)).squareRoot())
            i += frameLength
        }
        return out
    }

    private static func percentile(_ sorted: [Float], _ p: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }
}
