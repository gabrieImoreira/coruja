import AppKit
import ArgumentParser
import Foundation

@main
struct Coruja: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "coruja",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self, Transcribe.self, Summarize.self, PrefetchModel.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        // Always a real Dock icon, not just while recording. The menu bar
        // icon is not a reliable sole entry point — macOS drops third-party
        // status items first when the bar is full, with no warning and no
        // overflow chevron on some setups (confirmed live on a crowded Mac).
        // A permanent Dock icon means coruja is always reachable regardless
        // of menu bar state, same as any ordinary app (Cmd+Tab, clicking the
        // Dock icon, right-click menu).
        app.setActivationPolicy(.regular)

        let delegate = AppDelegate()
        app.delegate = delegate

        let controller = AppController(root: root)
        delegate.onDockMenu = { [weak controller] in controller?.dockMenu() ?? NSMenu() }
        delegate.onReopen = { [weak controller] in controller?.openNotes() }
        delegate.onWillTerminate = { [weak controller] in controller?.prepareForTermination() }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "coruja up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

/// Supplies the Dock's right-click menu and handles clicking the Dock icon
/// (which opens the notes window, standard "reopen" behavior for an app with
/// no visible windows). Kept separate from AppController because
/// NSApplicationDelegate must be an NSObject subclass.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onDockMenu: (() -> NSMenu)?
    var onReopen: (() -> Void)?
    var onWillTerminate: (() -> Void)?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        onDockMenu?()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { onReopen?() }
        return true
    }

    /// Cmd-Q / Dock "Quit" — standard on a .regular app, unlike the old pure
    /// menu-bar daemon — must still finalize any in-progress recording.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        onWillTerminate?()
        return .terminateNow
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController: NSObject {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?

    private let meetingDetector = MeetingDetector()
    private let meetingPrompt = MeetingPromptWindow()
    private var meetingPollTimer: Timer?
    /// Set when a recording was started from the meeting prompt, to the URL
    /// that triggered it. Only a meeting ending that matches this URL
    /// auto-stops — a manually started recording is never auto-stopped by
    /// an unrelated Chrome tab closing.
    private var meetingRecordingURL: String?

    private var notesWindow: NotesWindowController?
    private var settingsWindow: SettingsWindowController?
    private let recordingStatus = RecordingStatus()

    init(root: URL) {
        self.root = root
        super.init()
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onOpenNotes = { [weak self] in self?.openNotes() }
        menuBar.onOpenSettings = { [weak self] in self?.openSettings() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)
        installHotkey()
        setupMeetingDetector()

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.warmUp()
            await transcription.resumePending(root: root)
        }
    }

    /// Polls Chrome for a Google Meet / Teams tab (see MeetingDetector) and
    /// prompts to record when one shows up; auto-stops if that same meeting
    /// ends while coruja is still recording it.
    private func setupMeetingDetector() {
        Task { [meetingDetector] in
            await meetingDetector.configure(
                onStarted: { [weak self] url in
                    Task { @MainActor in self?.handleMeetingDetected(url) }
                },
                onEnded: { [weak self] url in
                    Task { @MainActor in self?.handleMeetingEnded(url) }
                }
            )
        }
        // Created on the main actor so it rides NSApplication's main run
        // loop — a Timer made inside MeetingDetector's own (non-main) actor
        // has no run loop pumping it and silently never fires.
        meetingPollTimer = Timer.scheduledTimer(withTimeInterval: MeetingDetector.pollInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.meetingDetector.poll() }
        }
    }

    private func handleMeetingDetected(_ url: String) {
        guard session == nil else { return } // already recording something
        meetingPrompt.show(
            onRecord: { [weak self] in
                self?.meetingRecordingURL = url
                self?.startSession()
            },
            onIgnore: {}
        )
    }

    private func handleMeetingEnded(_ url: String) {
        guard meetingRecordingURL == url, session != nil else { return }
        meetingRecordingURL = nil
        stopSession()
    }

    /// Global toggle-recording shortcut (⌃⌥⌘R), independent of the menu bar
    /// icon. macOS overlays third-party status items with its own orange
    /// microphone-in-use badge while recording — that badge isn't always
    /// clickable, so a crowded menu bar (or the system's own privacy
    /// indicator) can leave the icon with no working click target. The
    /// hotkey is the reliable way to stop a recording when that happens.
    /// Requires Input Monitoring permission (System Settings → Privacy &
    /// Security → Input Monitoring) — silently inert until granted, no crash.
    private static let hotkeyKeyCode: UInt16 = 15 // kVK_ANSI_R
    private static let hotkeyModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

    private func installHotkey() {
        func matches(_ event: NSEvent) -> Bool {
            event.keyCode == Self.hotkeyKeyCode
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == Self.hotkeyModifiers
        }
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard matches(event) else { return }
            Task { @MainActor [weak self] in self?.toggle() }
        }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard matches(event) else { return event }
            self?.toggle()
            return nil
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit. Used by
    /// the menu's "Quit coruja" and Ctrl-C.
    func shutdown() {
        prepareForTermination()
        NSApp.terminate(nil)
    }

    /// Same cleanup as shutdown(), without triggering termination itself —
    /// for AppDelegate.applicationShouldTerminate, called for standard
    /// Cmd-Q/Dock-Quit on a .regular app, which must not recurse into
    /// another NSApp.terminate() call.
    func prepareForTermination() {
        stopSession()
        if let globalHotkeyMonitor { NSEvent.removeMonitor(globalHotkeyMonitor) }
        if let localHotkeyMonitor { NSEvent.removeMonitor(localHotkeyMonitor) }
        meetingPollTimer?.invalidate()
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "Não foi possível iniciar a gravação", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        recordingStatus.isRecording = true
        recordingStatus.elapsed = "0:00"
        // macOS overlays a system microphone badge on top of the menu bar
        // icon while recording, which can leave it unclickable — this
        // notification is the only reliable confirmation that recording
        // actually started (and a reminder that ⌃⌥⌘R stops it).
        notifyUser(title: "Gravando", body: "⌃⌥⌘R ou o ícone no Dock para parar")
        // The Dock icon (always present, see runMain) badges while
        // recording — unlike the menu bar icon, it isn't subject to macOS
        // dropping it for space or overlaying its own mic-in-use badge, so
        // right-click → Stop Recording always works.
        NSApp.dockTile.badgeLabel = "●"
        NSApp.dockTile.display()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Right-click (or hold-click) menu for coruja's (always visible) Dock
    /// icon — a click target for Start/Stop that macOS can't paper over or
    /// drop for space, unlike the menu bar icon.
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: session == nil ? "Iniciar gravação" : "Parar gravação",
            action: #selector(dockMenuToggle),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func dockMenuToggle() { toggle() }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        notifyUser(title: "Gravação encerrada", body: "\(elapsed) · \(session.dir.lastPathComponent)")
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)
        recordingStatus.isRecording = false
        recordingStatus.elapsed = nil
        NSApp.dockTile.badgeLabel = nil
        meetingRecordingURL = nil

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcrevendo \(name) · \(queued) na fila" : "transcrevendo \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("falha ao transcrever · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        menuBar.update(recording: true, elapsed: elapsed)
        recordingStatus.elapsed = elapsed
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// Opens the session-list + transcript-reader window (see
    /// NotesWindowController) — reachable via the menu, the Dock icon
    /// (clicking it when no window is open — see AppDelegate.onReopen), or
    /// programmatically. Not `private`: AppDelegate's onReopen calls it too.
    func openNotes() {
        if let notesWindow {
            notesWindow.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NotesWindowController(
            root: root,
            status: recordingStatus,
            onToggleRecording: { [weak self] in self?.toggle() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        controller.onClose = { [weak self] in self?.notesWindow = nil }
        notesWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the settings panel (see SettingsWindowController) — reachable
    /// via the menu bar (⌘,) or the gear icon in the notes window.
    func openSettings() {
        if let settingsWindow {
            settingsWindow.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SettingsWindowController()
        controller.onClose = { [weak self] in self?.settingsWindow = nil }
        settingsWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
