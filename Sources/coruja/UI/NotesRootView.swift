import AppKit
import SwiftUI

/// Session list + transcript reader — the real, ordinary-window surface
/// coruja was missing when its only UI was a menu bar icon macOS can paper
/// over and a Dock icon that only appeared (and only helped) while
/// recording. No summarization (unlike coconote) — just the recordings and
/// their transcripts, browsable.
///
/// Visual design follows the "Janela Principal" handoff: a document-style
/// transcript (serif body, no chat bubbles), sessions grouped by day, a
/// monochrome palette, and a light/dark toggle independent of the system.
struct NotesRootView: View {
    let root: URL
    @ObservedObject var status: RecordingStatus
    let onToggleRecording: () -> Void

    @AppStorage("corujaDarkMode") private var isDarkMode = false

    @State private var sessions: [SessionEntry] = []
    @State private var selection: URL?
    @State private var transcript: TranscriptDTO?
    @State private var transcriptFallback: String = ""
    @State private var copied = false
    @State private var recordDotPulsed = false
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @StateObject private var player = AudioPlayerModel()

    private var theme: Theme { Theme(isDark: isDarkMode) }

    var body: some View {
        VStack(spacing: 0) {
            recordingBar
            Divider().overlay(theme.border)
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(theme.border)
                detail
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .background(theme.windowBg)
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .onAppear(perform: reload)
        .onChange(of: status.isRecording) { wasRecording, isRecording in
            // A session folder only appears once stop() writes .meta.json —
            // refresh the list right when recording flips off.
            if wasRecording, !isRecording { reload() }
        }
        .task {
            // Transcription finishes well after recording stops (minutes,
            // not instant) — poll while the window is open so "Processando…"
            // flips to "Transcrito" on its own, no manual refresh needed.
            // Cancels automatically when the window closes.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                reload()
            }
        }
        .confirmationDialog(
            "Excluir esta gravação?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { session in
            Button("Excluir", role: .destructive) { delete(session) }
            Button("Cancelar", role: .cancel) {}
        } message: { session in
            Text("\(session.dayGroupLabel), \(session.timeLabel) será apagada permanentemente — áudio e transcrição. Essa ação não pode ser desfeita.")
        }
    }

    @State private var pendingDelete: SessionEntry?

    // MARK: - Recording bar

    private var recordingBar: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
                )

            Button(action: onToggleRecording) {
                HStack(spacing: 9) {
                    if status.isRecording {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 9, height: 9)
                            .opacity(recordDotPulsed ? 0.35 : 1)
                    } else {
                        Circle()
                            .fill(theme.recordIdleColor)
                            .frame(width: 8, height: 8)
                    }
                    Text(status.isRecording ? "Parar gravação" : "Iniciar gravação")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(status.isRecording ? .white : theme.recordIdleColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(status.isRecording ? Theme.recordRed : theme.recordIdleBg)
                )
            }
            .buttonStyle(.plain)
            .onChange(of: status.isRecording) { _, isRecording in
                if isRecording {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                        recordDotPulsed = true
                    }
                } else {
                    recordDotPulsed = false
                }
            }

            if status.isRecording {
                Text(status.elapsed ?? "0:00")
                    .font(.system(size: 13, weight: .semibold).monospaced())
                    .foregroundStyle(Theme.recordRed)
            }

            Spacer()

            Text("~/Recordings")
                .font(.system(size: 12))
                .foregroundStyle(theme.pathColor)

            themeToggle
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(theme.windowBg)
    }

    private var themeToggle: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isDarkMode.toggle() }
            } label: {
                ZStack(alignment: isDarkMode ? .trailing : .leading) {
                    Capsule()
                        .fill(isDarkMode ? Color(hex: 0xF2F2F0) : Color.black.opacity(0.2))
                    Circle()
                        .fill(isDarkMode ? Color(hex: 0x1A1A1A) : .white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                        .padding(2)
                }
                .frame(width: 34, height: 20)
            }
            .buttonStyle(.plain)

            Text(isDarkMode ? "Escuro" : "Claro")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.pathColor)
                .frame(width: 42, alignment: .leading)
        }
    }

    private var currentSession: SessionEntry? {
        sessions.first { $0.id == selection }
    }

    // MARK: - Sidebar

    private var groupedSessions: [(label: String, items: [SessionEntry])] {
        var order: [String] = []
        var buckets: [String: [SessionEntry]] = [:]
        for session in sessions {
            let label = session.dayGroupLabel
            if buckets[label] == nil { order.append(label) }
            buckets[label, default: []].append(session)
        }
        return order.map { (label: $0, items: buckets[$0] ?? []) }
    }

    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(groupedSessions, id: \.label) { group in
                    Text(group.label.uppercased())
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(theme.groupLabelColor)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                    ForEach(group.items) { session in
                        sidebarRow(session)
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .frame(width: 250)
        .background(theme.sidebarBg)
    }

    private func sidebarRow(_ session: SessionEntry) -> some View {
        let selected = session.id == selection
        return VStack(alignment: .leading, spacing: 3) {
            if let title = session.title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.rowTitleColor)
                    .lineLimit(1)
                Text("\(session.dayGroupLabel), \(session.timeLabel)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.rowDurationColor)
                    .lineLimit(1)
            } else {
                Text("\(session.dayGroupLabel), \(session.timeLabel)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.rowTitleColor)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(session.hasTranscript ? theme.dotOn : theme.dotOff)
                    .frame(width: 5, height: 5)
                Text(session.hasTranscript ? "Transcrito" : "Processando…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.rowStatusColor)
                Spacer()
                if let duration = session.durationLabel {
                    Text(duration)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(theme.rowDurationColor)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? theme.rowSelectedBg : .clear)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { selection = session.id }
    }

    // MARK: - Detail

    private var detail: some View {
        Group {
            if let session = currentSession {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            header(for: session)

                            if FileManager.default.fileExists(atPath: session.audioURL.path) {
                                playerCard
                                    .padding(.top, 4)
                            }

                            transcriptBody
                                .padding(.top, 26)
                                .padding(.bottom, 24)
                        }
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.top, 32)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity)
                    }
                    .background(theme.windowBg)

                    Divider().overlay(theme.border)
                    actionBar(for: session)
                }
                .onChange(of: selection, initial: true) { _, _ in loadContent(for: session) }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.windowBg)
    }

    private func header(for session: SessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if editingTitle {
                TextField("Nome da reunião", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.headerTitleColor)
                    .onSubmit { saveTitle(session) }
                    .onExitCommand { editingTitle = false }
            } else {
                HStack(spacing: 8) {
                    Text(session.title ?? "\(session.dayGroupLabel), \(session.timeLabel)")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(theme.headerTitleColor)
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Button {
                        titleDraft = session.title ?? ""
                        editingTitle = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.metaColor)
                    }
                    .buttonStyle(.plain)
                    .help("Editar nome")
                }
            }
            if session.title != nil {
                Text("\(session.dayGroupLabel), \(session.timeLabel)")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.metaColor)
            }
            if let transcript {
                Text("\(transcript.segments.count) trechos · \(transcript.model)")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.metaColor)
            }
        }
        .padding(.bottom, 22)
    }

    private func saveTitle(_ session: SessionEntry) {
        SessionScanner.saveTitle(titleDraft, for: session)
        editingTitle = false
        reload()
    }

    private var playerCard: some View {
        HStack(spacing: 16) {
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.playIconColor)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(theme.playButtonBg))
            }
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                Slider(
                    value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                    in: 0...max(player.duration, 0.1)
                )
                .tint(theme.playButtonBg)
                HStack {
                    Text(Self.formatTime(player.currentTime))
                    Spacer()
                    Text(Self.formatTime(player.duration))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(theme.timeColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(theme.playerCardBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .padding(.bottom, 26)
    }

    private var transcriptBody: some View {
        Group {
            if let transcript, !transcript.segments.isEmpty {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(transcript.segments) { segment in
                        transcriptParagraph(segment)
                    }
                }
            } else {
                Text(transcriptFallback.isEmpty ? "Transcrição ainda não disponível." : transcriptFallback)
                    .font(.system(size: 13.5))
                    .italic()
                    .foregroundStyle(theme.fallbackColor)
            }
        }
    }

    private func transcriptParagraph(_ segment: TranscriptDTO.Segment) -> some View {
        let isMe = segment.speaker == "me"
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(isMe ? "EU" : segment.speaker.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(isMe ? theme.speakerMe : theme.speakerOther)
                Spacer()
                Text(Self.formatMs(segment.start_ms))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.timestampColor)
            }
            Text(segment.text)
                .font(.system(size: 14, weight: .regular, design: .default))
                .lineSpacing(4)
                .foregroundStyle(theme.bodyColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 32))
                .foregroundStyle(theme.metaColor)
            Text(sessions.isEmpty ? "Nenhuma gravação ainda" : "Selecione uma gravação")
                .font(.system(size: 13))
                .foregroundStyle(theme.metaColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.windowBg)
    }

    private func actionBar(for session: SessionEntry) -> some View {
        HStack(spacing: 10) {
            actionButton(copied ? "Copiado" : "Copiar transcrição", icon: copied ? "checkmark" : "doc.on.doc") {
                copyTranscript()
            }
            actionButton("Abrir pasta", icon: "folder") {
                NSWorkspace.shared.open(session.id)
            }

            Spacer()

            Button("Excluir gravação") { pendingDelete = session }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.deleteColor)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(theme.windowBg)
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(theme.actionBtnColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(theme.actionBtnBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcriptFallback.isEmpty ? plainTextFromSegments() : transcriptFallback, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func plainTextFromSegments() -> String {
        guard let transcript else { return "" }
        return transcript.segments
            .map { "[\(Self.formatMs($0.start_ms))] \($0.speaker == "me" ? "Eu" : $0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    private func loadContent(for session: SessionEntry) {
        editingTitle = false
        transcript = TranscriptDTO.load(from: session.transcriptJSONURL)
        transcriptFallback = transcript == nil ? SessionScanner.transcriptText(for: session) : ""
        if FileManager.default.fileExists(atPath: session.audioURL.path) {
            player.load(session.audioURL)
        } else {
            player.stop()
        }
    }

    private func delete(_ session: SessionEntry) {
        if selection == session.id {
            player.stop()
            selection = nil
        }
        try? FileManager.default.removeItem(at: session.id)
        pendingDelete = nil
        reload()
    }

    private func reload() {
        sessions = SessionScanner.scan(root: root)
        if selection == nil { selection = sessions.first?.id }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func formatMs(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
