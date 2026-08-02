import Foundation

/// Polls Google Chrome's open tabs (via AppleScript) for a Google Meet or
/// Microsoft Teams meeting URL. There's no public macOS API for "a meeting
/// is active" — this is a heuristic on tab URLs, so it fires on the
/// pre-join lobby too, not just an actually-joined call. That's fine here:
/// detection only ever triggers a dismissable prompt, never an automatic
/// recording, so a false positive costs a tap, not a surprise recording.
///
/// First poll triggers a one-time "coruja wants to control Google Chrome"
/// Automation permission prompt (System Settings → Privacy & Security →
/// Automation) — required for AppleScript to read tab URLs at all.
actor MeetingDetector {
    /// How often AppController's (main-actor, NSApplication-run-loop-backed)
    /// timer should call poll(). A Timer created inside a plain actor has no
    /// reliable run loop to fire on — Swift Concurrency executor threads
    /// don't pump one — so polling is driven from the main actor instead.
    static let pollInterval: TimeInterval = 5
    private static let meetingURLPattern = try! NSRegularExpression(
        pattern: #"meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}|teams\.(microsoft|live)\.com/[^\s]*(meet|call)"#,
        options: [.caseInsensitive]
    )

    private var currentMeetingURL: String?

    /// Fired when a meeting URL appears that wasn't there last poll, with the
    /// matched URL. Fired when the URL that triggered it disappears from
    /// every Chrome tab (closed, navigated away, or Chrome quit).
    private var onMeetingStarted: (@Sendable (String) -> Void)?
    private var onMeetingEnded: (@Sendable (String) -> Void)?

    func configure(
        onStarted: @escaping @Sendable (String) -> Void,
        onEnded: @escaping @Sendable (String) -> Void
    ) {
        onMeetingStarted = onStarted
        onMeetingEnded = onEnded
    }

    func poll() {
        let urls = Self.chromeTabURLs()
        let match = urls.first { Self.matches($0) }

        if let match, currentMeetingURL == nil {
            currentMeetingURL = match
            onMeetingStarted?(match)
        } else if currentMeetingURL != nil, !urls.contains(where: { $0 == currentMeetingURL }) {
            let ended = currentMeetingURL!
            currentMeetingURL = nil
            onMeetingEnded?(ended)
        }
    }

    private static func matches(_ url: String) -> Bool {
        meetingURLPattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    /// Runs a short AppleScript via osascript to list every tab URL in every
    /// Chrome window, one per line. Checks `is running` first so a closed
    /// Chrome never gets launched just to be polled.
    private static func chromeTabURLs() -> [String] {
        let script = """
        if application "Google Chrome" is running then
            tell application "Google Chrome"
                set output to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set output to output & (URL of t) & linefeed
                    end repeat
                end repeat
                return output
            end tell
        else
            return ""
        end if
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }
}
