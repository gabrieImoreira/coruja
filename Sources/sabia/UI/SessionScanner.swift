import Foundation

/// One row in the notes window's session list.
struct SessionEntry: Identifiable, Hashable {
    let id: URL // the session folder
    let displayName: String
    let hasTranscript: Bool

    var transcriptURL: URL { id.appendingPathComponent(TranscriptionCoordinator.transcriptMDFileName) }
    var transcriptJSONURL: URL { id.appendingPathComponent(TranscriptionCoordinator.transcriptJSONFileName) }
    var audioURL: URL { id.appendingPathComponent(TranscriptionCoordinator.audioFileName) }
}

/// Scans the recordings root and turns each session's timestamp-only folder
/// name (RecordingSession.folderFormat, e.g. "2026-08-01 21h50", possibly
/// with a "-2" collision suffix) into a locale-formatted display date, so
/// the notes window never shows the raw folder name.
enum SessionScanner {
    private static let folderDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH'h'mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        f.locale = Locale(identifier: "pt_BR")
        return f
    }()

    static func scan(root: URL) -> [SessionEntry] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // newest first
            .map { dir in
                let name = dir.lastPathComponent
                let display = parseDate(from: name).map(displayFormatter.string) ?? name
                let hasTranscript = fm.fileExists(
                    atPath: dir.appendingPathComponent(TranscriptionCoordinator.transcriptMDFileName).path
                )
                return SessionEntry(id: dir, displayName: display, hasTranscript: hasTranscript)
            }
    }

    static func transcriptText(for entry: SessionEntry) -> String {
        (try? String(contentsOf: entry.transcriptURL, encoding: .utf8))
            ?? "Transcrição ainda não disponível (pendente ou em processamento)."
    }

    private static func parseDate(from folderName: String) -> Date? {
        if let date = folderDateFormatter.date(from: folderName) { return date }
        // Strip a "-N" collision suffix (RecordingSession appends one when two
        // sessions land in the same minute) and retry.
        if let dash = folderName.range(of: "-", options: .backwards),
           Int(folderName[dash.upperBound...]) != nil
        {
            return folderDateFormatter.date(from: String(folderName[..<dash.lowerBound]))
        }
        return nil
    }
}
