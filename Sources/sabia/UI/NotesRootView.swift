import AppKit
import SwiftUI

/// Session list + transcript reader — the real, ordinary-window surface
/// sabia was missing when its only UI was a menu bar icon macOS can paper
/// over and a Dock icon that only appeared (and only helped) while
/// recording. No summarization (unlike coconote) — just the recordings and
/// their transcripts, browsable.
struct NotesRootView: View {
    let root: URL
    @ObservedObject var status: RecordingStatus
    let onToggleRecording: () -> Void

    @State private var sessions: [SessionEntry] = []
    @State private var selection: URL?
    @State private var transcriptText: String = ""
    @State private var copied = false
    @StateObject private var player = AudioPlayerModel()

    var body: some View {
        VStack(spacing: 0) {
            recordingBar
            Divider()
            splitView
        }
        .frame(minWidth: 680, minHeight: 440)
        .onAppear(perform: reload)
        .onChange(of: status.isRecording) { wasRecording, isRecording in
            // A session folder only appears once stop() writes .meta.json —
            // refresh the list right when recording flips off.
            if wasRecording, !isRecording { reload() }
        }
    }

    private var recordingBar: some View {
        HStack {
            Button(action: onToggleRecording) {
                Label(
                    status.isRecording ? "Parar gravação" : "Iniciar gravação",
                    systemImage: status.isRecording ? "stop.circle.fill" : "record.circle"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(status.isRecording ? .red : .accentColor)

            if status.isRecording {
                Text(status.elapsed ?? "0:00")
                    .monospacedDigit()
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding()
    }

    private var splitView: some View {
        NavigationSplitView {
            List(sessions, selection: $selection) { session in
                HStack {
                    Text(session.displayName)
                    Spacer()
                    if !session.hasTranscript {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                            .help("Transcrição pendente ou em processamento")
                    }
                }
                .tag(session.id)
            }
            .navigationTitle("sabia")
            .toolbar {
                ToolbarItem {
                    Button(action: reload) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Atualizar lista")
                }
            }
        } detail: {
            if let session = sessions.first(where: { $0.id == selection }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.displayName)
                        .font(.title2).bold()
                        .padding()
                    Divider()
                    if FileManager.default.fileExists(atPath: session.audioURL.path) {
                        playerBar
                        Divider()
                    }
                    ScrollView {
                        Text(transcriptText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    Divider()
                    HStack {
                        Button {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(transcriptText, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: {
                            Label(copied ? "Copiado" : "Copiar transcrição", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        Button("Abrir pasta") { NSWorkspace.shared.open(session.id) }
                        Spacer()
                    }
                    .padding()
                }
                .onChange(of: selection, initial: true) { _, _ in
                    transcriptText = SessionScanner.transcriptText(for: session)
                    if FileManager.default.fileExists(atPath: session.audioURL.path) {
                        player.load(session.audioURL)
                    } else {
                        player.stop()
                    }
                }
            } else {
                Text(sessions.isEmpty ? "Nenhuma gravação ainda" : "Selecione uma gravação")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var playerBar: some View {
        HStack(spacing: 12) {
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .font(.title3)

            Text(Self.formatTime(player.currentTime))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .font(.caption)

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.1)
            )

            Text(Self.formatTime(player.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func reload() {
        sessions = SessionScanner.scan(root: root)
        if selection == nil { selection = sessions.first?.id }
    }
}
