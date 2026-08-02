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
                    ScrollView {
                        Text(transcriptText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    Divider()
                    HStack {
                        Button("Reproduzir áudio") { NSWorkspace.shared.open(session.audioURL) }
                            .disabled(!FileManager.default.fileExists(atPath: session.audioURL.path))
                        Button("Abrir pasta") { NSWorkspace.shared.open(session.id) }
                        Spacer()
                    }
                    .padding()
                }
                .onChange(of: selection, initial: true) { _, _ in
                    transcriptText = SessionScanner.transcriptText(for: session)
                }
            } else {
                Text(sessions.isEmpty ? "Nenhuma gravação ainda" : "Selecione uma gravação")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func reload() {
        sessions = SessionScanner.scan(root: root)
        if selection == nil { selection = sessions.first?.id }
    }
}
