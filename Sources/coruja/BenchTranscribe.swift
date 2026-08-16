import ArgumentParser
import Foundation

/// Re-transcribes one already-recorded session with the current WhisperEngine
/// and writes the result next to the real transcript, without touching it —
/// `.transcript.json` stays the coordinator's, this writes `.transcript-new.json`
/// so a config change can be A/B'd against a real session with
/// `scripts/eval_transcript.py` before it ever reaches the live queue.
struct Transcribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Re-run transcription on a recorded session for benchmarking (writes .transcript-new.json, never touches .transcript.json)."
    )

    @Argument(help: "Session directory (e.g. ~/Recordings/\"2026-08-03 15h06\").")
    var session: String

    @Option(name: .long, help: "Output file name, relative to the session directory.")
    var out: String = ".transcript-new.json"

    func run() throws {
        let dir = URL(fileURLWithPath: (session as NSString).expandingTildeInPath)
        MainActor.assumeIsolated {
            let task = Task {
                do {
                    try await Self.runTranscription(dir: dir, outName: out)
                } catch {
                    FileHandle.standardError.write(Data("transcribe failed: \(error)\n".utf8))
                    Foundation.exit(1)
                }
                Foundation.exit(0)
            }
            _ = task
            RunLoop.main.run()
        }
    }

    private static func runTranscription(dir: URL, outName: String) async throws {
        let metaURL = dir.appendingPathComponent(RecordingSession.metaFileName)
        guard
            let data = try? Data(contentsOf: metaURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else {
            throw ValidationError("can't read \(metaURL.path)")
        }
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]

        var tracks: [(file: String, speaker: String, offsetMs: Int)] = []
        if let mic = files["mic"] {
            tracks.append((mic, "me", offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append((system, "them", offsets["system"] ?? 0))
        }

        let engine = WhisperEngine(language: Config.transcriptionLanguage())
        FileHandle.standardError.write(Data("preparing whisper engine (first run downloads/specializes the model, can take minutes)...\n".utf8))
        try await engine.prepare()

        struct OutSegment: Codable {
            let speaker: String
            let start_ms: Int
            let end_ms: Int
            let text: String
        }
        struct OutTranscript: Codable {
            let engine: String
            let model: String
            let created_at: String
            let segments: [OutSegment]
        }

        var merged: [OutSegment] = []
        for track in tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                FileHandle.standardError.write(Data("skipping missing track \(track.file)\n".utf8))
                continue
            }
            FileHandle.standardError.write(Data("transcribing \(track.file)...\n".utf8))
            let segments = try await engine.transcribe(audio)
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                OutSegment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let out = OutTranscript(
            engine: engine.name, model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(out).write(to: dir.appendingPathComponent(outName), options: .atomic)
        FileHandle.standardError.write(Data("wrote \(dir.appendingPathComponent(outName).path) — \(merged.count) segments\n".utf8))
    }
}
