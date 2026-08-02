import AVFoundation
import Foundation

/// Combines the two independently-offset mono tracks (mic + system, each
/// hidden as .mic.caf/.system.caf) into a single playable audio.m4a — the
/// one audio artifact a user actually sees in the session folder. AVFoundation
/// mixes overlapping tracks in a composition automatically; no AVAudioMix
/// (volume ramps, per-track processing) is needed for a plain sum.
enum AudioMixer {
    enum MixError: Error, CustomStringConvertible {
        case noPlayableTracks

        var description: String {
            switch self {
            case .noPlayableTracks: return "no readable audio tracks to mix"
            }
        }
    }

    static func mixDown(tracks: [(url: URL, offsetMs: Int)], to output: URL) async throws {
        let composition = AVMutableComposition()
        var added = false

        for track in tracks where FileManager.default.fileExists(atPath: track.url.path) {
            let asset = AVURLAsset(url: track.url)
            guard
                let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                let duration = try? await asset.load(.duration),
                duration.seconds > 0
            else { continue }

            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            let offset = CMTime(seconds: Double(track.offsetMs) / 1000, preferredTimescale: 600)
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: assetTrack,
                at: offset
            )
            added = true
        }

        guard added else { throw MixError.noPlayableTracks }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MixError.noPlayableTracks
        }
        // A retry after a prior failed attempt shouldn't trip over a
        // partial file the export session refuses to overwrite.
        try? FileManager.default.removeItem(at: output)
        try await export.export(to: output, as: .m4a)
    }
}
