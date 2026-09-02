import ArgumentParser
import Foundation

/// Runs the OpenAI summary pass over an already-transcribed session's
/// `.transcript.json`, without going through the full recording pipeline —
/// for testing/tuning the summary prompt and OpenAI API key setup in
/// isolation. Writes `summary-test.md` next to the session, never touching
/// `summary.md`.
struct Summarize: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the local-LLM summary pass on an already-transcribed session (writes summary-test.md)."
    )

    @Argument(help: "Session directory (e.g. ~/Recordings/\"2026-08-03 15h06\").")
    var session: String

    func run() throws {
        let dir = URL(fileURLWithPath: (session as NSString).expandingTildeInPath)
        MainActor.assumeIsolated {
            let task = Task {
                do {
                    try await Self.runSummary(dir: dir)
                } catch {
                    FileHandle.standardError.write(Data("summarize failed: \(error)\n".utf8))
                    Foundation.exit(1)
                }
                Foundation.exit(0)
            }
            _ = task
            RunLoop.main.run()
        }
    }

    private static func runSummary(dir: URL) async throws {
        struct InSegment: Codable { let speaker: String; let text: String; let start_ms: Int }
        struct InTranscript: Codable { let segments: [InSegment] }

        let transcriptURL = dir.appendingPathComponent(".transcript.json")
        let data = try Data(contentsOf: transcriptURL)
        let transcript = try JSONDecoder().decode(InTranscript.self, from: data)

        let timed = transcript.segments.map {
            SummaryEngine.TimedSegment(speaker: $0.speaker, text: $0.text, startMs: $0.start_ms)
        }

        guard let apiKey = Config.openaiApiKey() else {
            FileHandle.standardError.write(Data("no OpenAI API key configured (see Settings)\n".utf8))
            throw SummaryEngine.SummaryError.missingAPIKey
        }
        let type = SummaryEngine.SummaryType(rawValue: Config.summaryType()) ?? .topicos
        FileHandle.standardError.write(Data("calling OpenAI (\(Config.llmModel()), \(type.rawValue))...\n".utf8))
        let summary = try await SummaryEngine.summarize(
            segments: timed,
            apiKey: apiKey,
            model: Config.llmModel(),
            summaryType: type
        )

        let heading = type == .ata ? "# Ata da reunião" : "# Resumo"
        var lines = [heading, "", summary.resumo, ""]
        if !summary.itensDeAcao.isEmpty {
            lines.append("## Itens de ação")
            lines.append("")
            for item in summary.itensDeAcao {
                var line = "- \(item.item)"
                if let r = item.responsavel { line += " — **\(r)**" }
                if let p = item.prazo { line += " (prazo: \(p))" }
                lines.append(line)
            }
        }
        let rendered = lines.joined(separator: "\n")
        try rendered.write(to: dir.appendingPathComponent("summary-test.md"), atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("wrote \(dir.appendingPathComponent("summary-test.md").path)\n".utf8))
        print(rendered)
    }
}
