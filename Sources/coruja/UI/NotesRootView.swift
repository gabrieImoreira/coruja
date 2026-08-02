import AppKit
import SwiftUI

/// Session list + transcript reader — the real, ordinary-window surface
/// coruja was missing when its only UI was a menu bar icon macOS can paper
/// over and a Dock icon that only appeared (and only helped) while
/// recording. No summarization (unlike coconote) — just the recordings and
/// their transcripts, browsable.
struct NotesRootView: View {
    let root: URL
    @ObservedObject var status: RecordingStatus
    let onToggleRecording: () -> Void

    @State private var sessions: [SessionEntry] = []
    @State private var selection: URL?
    @State private var transcript: TranscriptDTO?
    @State private var transcriptFallback: String = ""
    @State private var copied = false
    @State private var pendingDelete: SessionEntry?
    @StateObject private var player = AudioPlayerModel()

    var body: some View {
        VStack(spacing: 0) {
            recordingBar
            Divider()
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear(perform: reload)
        .onChange(of: status.isRecording) { wasRecording, isRecording in
            // A session folder only appears once stop() writes .meta.json —
            // refresh the list right when recording flips off.
            if wasRecording, !isRecording { reload() }
        }
        .confirmationDialog(
            "Excluir esta gravação?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { session in
            Button("Excluir", role: .destructive) { delete(session) }
            Button("Cancelar", role: .cancel) {}
        } message: { session in
            Text("\(session.displayName) será apagada permanentemente — áudio e transcrição. Essa ação não pode ser desfeita.")
        }
    }

    /// A single, clearly-labeled bar rather than icon-only toolbar buttons —
    /// icon-only controls in the window toolbar read as unclear/cryptic in
    /// practice (confirmed live). Every action here has visible text.
    private var recordingBar: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 26, height: 26)

            Button(action: onToggleRecording) {
                Label(
                    status.isRecording ? "Parar gravação" : "Iniciar gravação",
                    systemImage: status.isRecording ? "stop.fill" : "record.circle.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(status.isRecording ? .red : .accentColor)

            if status.isRecording {
                Text(status.elapsed ?? "0:00")
                    .monospacedDigit()
                    .foregroundStyle(.red)
                    .font(.callout.weight(.medium))
            }
            Spacer()
        }
        .padding(14)
    }

    private var currentSession: SessionEntry? {
        sessions.first { $0.id == selection }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(sessions, selection: $selection) { session in
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(session.hasTranscript ? Color.accentColor : Color.orange)
                        .frame(width: 5, height: 5)
                    Text(session.hasTranscript ? "Transcrito" : "Processando…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
            .tag(session.id)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        .navigationTitle("Coruja")
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
                                    .padding(.horizontal, 28)
                                    .padding(.top, 18)
                            }

                            transcriptBody
                                .padding(.horizontal, 28)
                                .padding(.top, 24)
                                .padding(.bottom, 24)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(.background)

                    Divider()
                    actionBar(for: session)
                }
                .onChange(of: selection, initial: true) { _, _ in loadContent(for: session) }
            } else {
                emptyState
            }
        }
    }

    private func actionBar(for session: SessionEntry) -> some View {
        HStack(spacing: 10) {
            Button {
                copyTranscript()
            } label: {
                Label(copied ? "Copiado" : "Copiar transcrição", systemImage: copied ? "checkmark" : "doc.on.doc")
            }

            Button {
                NSWorkspace.shared.open(session.id)
            } label: {
                Label("Abrir pasta", systemImage: "folder")
            }

            Spacer()

            Button(role: .destructive) {
                pendingDelete = session
            } label: {
                Label("Excluir gravação", systemImage: "trash")
            }
        }
        .padding(14)
    }

    private func header(for session: SessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.displayName)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .textSelection(.enabled)
            if let transcript {
                Text("\(transcript.segments.count) trechos · \(transcript.model)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
    }

    private var playerCard: some View {
        HStack(spacing: 16) {
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                Slider(
                    value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                    in: 0...max(player.duration, 0.1)
                )
                HStack {
                    Text(Self.formatTime(player.currentTime))
                    Spacer()
                    Text(Self.formatTime(player.duration))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private var transcriptBody: some View {
        Group {
            if let transcript, !transcript.segments.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(transcript.segments) { segment in
                        transcriptRow(segment)
                    }
                }
            } else {
                Text(transcriptFallback.isEmpty ? "Transcrição ainda não disponível." : transcriptFallback)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func transcriptRow(_ segment: TranscriptDTO.Segment) -> some View {
        let isMe = segment.speaker == "me"
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isMe ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.14))
                Text(isMe ? "Eu" : "Outro")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isMe ? Color.accentColor : .secondary)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(Self.formatMs(segment.start_ms))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text(segment.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(sessions.isEmpty ? "Nenhuma gravação ainda" : "Selecione uma gravação")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
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
            .map { "[\(Self.formatMs($0.start_ms))] \($0.speaker == "me" ? "Eu" : "Outro"): \($0.text)" }
            .joined(separator: "\n")
    }

    private func loadContent(for session: SessionEntry) {
        transcript = TranscriptDTO.load(from: session.transcriptJSONURL)
        transcriptFallback = transcript == nil ? SessionScanner.transcriptText(for: session) : ""
        if FileManager.default.fileExists(atPath: session.audioURL.path) {
            player.load(session.audioURL)
        } else {
            player.stop()
        }
    }

    private func reload() {
        sessions = SessionScanner.scan(root: root)
        if selection == nil { selection = sessions.first?.id }
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
