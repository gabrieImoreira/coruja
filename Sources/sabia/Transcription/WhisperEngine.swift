import AVFoundation
import Foundation
import WhisperKit

/// Whisper large-v3-turbo via WhisperKit's Core ML port (Argmax). Multilingual —
/// unlike Parakeet, this is the engine sabia uses for Portuguese (and any other
/// language Whisper covers). Models (~600 MB - 1.5 GB depending on variant)
/// download once into WhisperKit's managed cache; after that, transcription
/// runs entirely on-device.
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

    /// - Parameters:
    ///   - language: ISO-639-1 code passed to WhisperKit's decoder (e.g. "pt"
    ///     for Portuguese). `nil` lets Whisper auto-detect per segment.
    ///   - modelVariant: WhisperKit model name. Defaults to the turbo variant
    ///     Argmax recommends for on-device speed/accuracy on Apple Silicon.
    init(language: String? = "pt", modelVariant: String = "large-v3-v20240930_turbo") {
        self.language = language
        self.modelVariant = modelVariant
        self.model = "whisperkit-\(modelVariant)"
    }

    func prepare() async throws {
        guard pipe == nil else { return }
        pipe = try await WhisperKit(WhisperKitConfig(model: modelVariant, verbose: false))
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let pipe else { throw EngineError.notPrepared }

        // Mirrors ParakeetEngine's guard: an empty/unreadable track must not
        // reach the decoder, where AVFoundation can raise an uncatchable ObjC
        // exception and take the whole daemon down.
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            chunkingStrategy: .vad
        )

        let results = try await pipe.transcribe(audioPath: audio.path, decodeOptions: options)

        return results.flatMap { result in
            result.segments.compactMap { segment -> TranscriptSegment? in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    text: text
                )
            }
        }
    }

    func release() async {
        pipe = nil
    }
}
