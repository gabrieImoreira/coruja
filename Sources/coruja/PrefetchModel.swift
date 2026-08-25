import ArgumentParser
import Foundation

/// Forces WhisperKit to download and cache the Whisper model this build uses,
/// without transcribing anything. Used by `scripts/build-app.sh` to make sure
/// the model is present in WhisperKit's local cache before it copies the
/// model into `Coruja.app/Contents/Resources` — see `WhisperEngine.prepare()`
/// for the other half (using that bundled copy instead of downloading again
/// at runtime). Kept as a real subcommand instead of a shell one-liner so the
/// model name stays defined in one place (`WhisperEngine`'s default).
struct PrefetchModel: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prefetch-model",
        abstract: "Download the Whisper model into WhisperKit's cache, if not already there. Used by the build script."
    )

    func run() throws {
        MainActor.assumeIsolated {
            let task = Task {
                do {
                    let engine = WhisperEngine(language: Config.transcriptionLanguage())
                    FileHandle.standardError.write(Data("checking whisper model cache (downloads on first run, can take minutes)...\n".utf8))
                    try await engine.prepare()
                    FileHandle.standardError.write(Data("model ready\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("prefetch failed: \(error)\n".utf8))
                    Foundation.exit(1)
                }
                Foundation.exit(0)
            }
            _ = task
            RunLoop.main.run()
        }
    }
}
