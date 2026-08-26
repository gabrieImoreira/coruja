import AppKit
import SwiftUI

/// Settings panel. Every field writes straight to config.json on change —
/// no Save button, same "just persist it" pattern as the dark-mode toggle
/// and the inline title editor in NotesRootView. Three fields
/// (`recordingsDirText`, `engine`, `language`) only take effect on the next
/// launch — the engine and recordings root are captured once at startup
/// (see AppController/TranscriptionCoordinator) and reloading the
/// transcription model mid-session costs on the order of minutes, so this
/// view says so instead of pretending it's live.
struct SettingsRootView: View {
    @AppStorage("corujaDarkMode") private var isDarkMode = false

    @State private var recordingsDirText = ""
    @State private var transcriptionEnabled = true
    @State private var engine = "whisper"
    @State private var language = "pt"
    @State private var micVoiceProcessing = false
    @State private var llmPassEnabled = false
    @State private var llmModel = "llama3.1:8b"

    private var theme: Theme { Theme(isDark: isDarkMode) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("Gravação") {
                    labeledRow("Pasta das gravações") {
                        HStack(spacing: 8) {
                            TextField("~/Recordings", text: $recordingsDirText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(theme.playerCardBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border))
                                .onSubmit(save)
                            Button("Escolher…", action: chooseFolder)
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(theme.playerCardBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border))
                        }
                        restartNote
                    }

                    toggleRow(
                        "Cancelamento de eco do microfone",
                        detail: "Ative se grava reuniões pela caixa de som (não fone) — evita que o áudio que sai da caixa volte a entrar no mic e seja transcrito duas vezes.",
                        isOn: $micVoiceProcessing
                    )
                }

                section("Transcrição") {
                    toggleRow("Transcrever automaticamente após gravar", isOn: $transcriptionEnabled)

                    labeledRow("Engine") {
                        Picker("", selection: $engine) {
                            Text("Whisper (padrão, multilíngue)").tag("whisper")
                            Text("Parakeet (só inglês, mais rápido)").tag("parakeet")
                        }
                        .labelsHidden()
                        .pickerStyle(.radioGroup)
                        restartNote
                    }

                    labeledRow("Idioma") {
                        Picker("", selection: $language) {
                            Text("Português").tag("pt")
                            Text("Inglês").tag("en")
                            Text("Espanhol").tag("es")
                            Text("Automático (detecta por trecho)").tag("auto")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260, alignment: .leading)
                        restartNote
                    }
                }

                section("Resumo e título automático") {
                    toggleRow(
                        "Gerar resumo, itens de ação e título com IA local",
                        detail: "Requer Ollama rodando na máquina (\"ollama serve\", com o modelo já baixado). Nada sai do computador — sem isso ligado, a coruja só transcreve.",
                        isOn: $llmPassEnabled
                    )

                    if llmPassEnabled {
                        labeledRow("Modelo Ollama") {
                            TextField("llama3.1:8b", text: $llmModel)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(theme.playerCardBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border))
                                .frame(maxWidth: 220)
                                .onSubmit(save)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(theme.windowBg)
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .onAppear(perform: load)
        .onChange(of: transcriptionEnabled) { _, _ in save() }
        .onChange(of: engine) { _, _ in save() }
        .onChange(of: language) { _, _ in save() }
        .onChange(of: micVoiceProcessing) { _, _ in save() }
        .onChange(of: llmPassEnabled) { _, _ in save() }
    }

    // MARK: - Sections

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(theme.groupLabelColor)
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
        }
    }

    private func labeledRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.rowTitleColor)
            content()
        }
    }

    private func toggleRow(_ label: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(label, isOn: isOn)
                .toggleStyle(.switch)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.rowTitleColor)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.metaColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var restartNote: some View {
        Text("Aplica na próxima vez que a coruja iniciar.")
            .font(.system(size: 10.5))
            .foregroundStyle(theme.metaColor)
    }

    // MARK: - Load / save

    private func load() {
        recordingsDirText = Config.recordingsDirRaw() ?? ""
        transcriptionEnabled = Config.transcriptionEnabled()
        engine = Config.transcriptionEngine()
        language = Config.transcriptionLanguageCode()
        micVoiceProcessing = Config.micVoiceProcessing()
        llmPassEnabled = Config.llmPassEnabled()
        llmModel = Config.llmModel()
    }

    private func save() {
        Config.save(
            recordingsDir: recordingsDirText,
            transcriptionEnabled: transcriptionEnabled,
            transcriptionEngine: engine,
            transcriptionLanguage: language,
            llmPassEnabled: llmPassEnabled,
            llmModel: llmModel,
            micVoiceProcessing: micVoiceProcessing
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Escolher"
        if !recordingsDirText.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (recordingsDirText as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recordingsDirText = url.path
        save()
    }
}
