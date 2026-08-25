import Foundation

/// One row in the notes window's session list.
struct SessionEntry: Identifiable, Hashable {
    let id: URL // the session folder
    let date: Date?
    let displayName: String
    let hasTranscript: Bool
    let durationSeconds: Int?
    /// From `.title` (see TitleEngine) — nil until the opt-in LLM pass
    /// writes one, or if the user never edited it in. Never the folder name.
    let title: String?

    var transcriptURL: URL { id.appendingPathComponent(TranscriptionCoordinator.transcriptMDFileName) }
    var transcriptJSONURL: URL { id.appendingPathComponent(TranscriptionCoordinator.transcriptJSONFileName) }
    var audioURL: URL { id.appendingPathComponent(TranscriptionCoordinator.audioFileName) }
    var titleURL: URL { id.appendingPathComponent(TitleEngine.titleFileName) }

    /// "Hoje", "Ontem", or a formatted date — the sidebar's section header.
    var dayGroupLabel: String {
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Hoje" }
        if cal.isDateInYesterday(date) { return "Ontem" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "d 'de' MMMM"
        return f.string(from: date)
    }

    /// "14:32" — paired with dayGroupLabel to make a row title like "Hoje, 14:32".
    var timeLabel: String {
        guard let date else { return displayName }
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    var durationLabel: String? {
        guard let durationSeconds else { return nil }
        return String(format: "%d:%02d", durationSeconds / 60, durationSeconds % 60)
    }
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
                let date = parseDate(from: name)
                let display = date.map(displayFormatter.string) ?? name
                let hasTranscript = fm.fileExists(
                    atPath: dir.appendingPathComponent(TranscriptionCoordinator.transcriptMDFileName).path
                )
                let duration = readDurationSeconds(dir: dir)
                let title = readTitle(dir: dir)
                return SessionEntry(
                    id: dir, date: date, displayName: display,
                    hasTranscript: hasTranscript, durationSeconds: duration,
                    title: title
                )
            }
    }

    static func transcriptText(for entry: SessionEntry) -> String {
        (try? String(contentsOf: entry.transcriptURL, encoding: .utf8))
            ?? "Transcrição ainda não disponível (pendente ou em processamento)."
    }

    private static func readTitle(dir: URL) -> String? {
        guard let raw = try? String(contentsOf: dir.appendingPathComponent(TitleEngine.titleFileName), encoding: .utf8)
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Overwrites (or, if `title` is empty, deletes) `.title` — used by the
    /// notes window's inline editor. Never touches the folder name itself.
    static func saveTitle(_ title: String, for entry: SessionEntry) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: entry.titleURL)
        } else {
            try? trimmed.write(to: entry.titleURL, atomically: true, encoding: .utf8)
        }
    }

    private static func readDurationSeconds(dir: URL) -> Int? {
        let url = dir.appendingPathComponent(RecordingSession.metaFileName)
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["duration_seconds"] as? Int
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
