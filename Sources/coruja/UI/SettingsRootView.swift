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
    @State private var llmModel = "gpt-4o-mini"
    @State private var summaryType = "topicos"
    @State private var apiKeyDraft = ""
    @State private var hasStoredAPIKey = false
    @State private var apiKeySaveError: String?
    @State private var updateCheckState: UpdateCheckState = .idle

    private enum UpdateCheckState {
        case idle, checking, upToDate, available(UpdateInfo), installing, failed(String)
    }

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
                        "Gerar resumo, itens de ação e título com OpenAI",
                        detail: "A transcrição desta reunião é enviada à OpenAI para gerar o texto — isso sai da regra normal da coruja de nada sair do computador. Sem isso ligado, a coruja só transcreve.",
                        isOn: $llmPassEnabled
                    )

                    if llmPassEnabled {
                        labeledRow("Chave da API OpenAI") {
                            HStack(spacing: 8) {
                                SecureField(hasStoredAPIKey ? "•••••••••••• (chave salva)" : "sk-...", text: $apiKeyDraft)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12.5))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(theme.playerCardBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border))
                                    .onSubmit(saveAPIKey)
                                Button("Salvar", action: saveAPIKey)
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(theme.playerCardBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border))
                                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            HStack(spacing: 6) {
                                Circle().fill(hasStoredAPIKey ? Color.green : Color.orange).frame(width: 6, height: 6)
                                Text(hasStoredAPIKey ? "Chave configurada" : "Nenhuma chave configurada")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.metaColor)
                            }
                            if let apiKeySaveError {
                                Text(apiKeySaveError)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                            }
                        }

                        labeledRow("Tipo de documento") {
                            Picker("", selection: $summaryType) {
                                Text("Resumo detalhado por tópico").tag("topicos")
                                Text("Ata da reunião").tag("ata")
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                        }

                        labeledRow("Modelo OpenAI") {
                            TextField("gpt-4o-mini", text: $llmModel)
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

                section("Sobre") {
                    labeledRow("Versão") {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.rowTitleColor)
                    }
                    updateCheckRow
                }
            }
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(theme.windowBg)
        .preferredColorScheme(isDarkMode ? .dark : .light)
        // Monochrome, same as the rest of the app — native Toggle/Picker
        // default to the system accent color (blue) otherwise.
        .tint(theme.rowTitleColor)
        .onAppear(perform: load)
        .onChange(of: transcriptionEnabled) { _, _ in save() }
        .onChange(of: engine) { _, _ in save() }
        .onChange(of: language) { _, _ in save() }
        .onChange(of: micVoiceProcessing) { _, _ in save() }
        .onChange(of: llmPassEnabled) { _, _ in save() }
        .onChange(of: summaryType) { _, _ in save() }
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

    private var updateCheckRow: some View {
        HStack(spacing: 8) {
            switch updateCheckState {
            case .idle:
                Button("Verificar atualizações", action: checkForUpdatesManually)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.playerCardBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border))
            case .checking:
                ProgressView().controlSize(.mini)
                Text("Verificando…").font(.system(size: 11)).foregroundStyle(theme.metaColor)
            case .upToDate:
                Text("Você já está na versão mais recente.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.metaColor)
            case .available(let info):
                Text("Versão \(info.version) disponível.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.rowTitleColor)
                Button("Atualizar", action: { installUpdate(info) })
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.playerCardBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border))
            case .installing:
                ProgressView().controlSize(.mini)
                Text("Instalando…").font(.system(size: 11)).foregroundStyle(theme.metaColor)
            case .failed(let message):
                Text(message).font(.system(size: 11)).foregroundStyle(.red)
                Button("Tentar de novo", action: checkForUpdatesManually)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
            }
        }
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
        summaryType = Config.summaryType()
        hasStoredAPIKey = OpenAIKeychain.get() != nil
    }

    private func save() {
        Config.save(
            recordingsDir: recordingsDirText,
            transcriptionEnabled: transcriptionEnabled,
            transcriptionEngine: engine,
            transcriptionLanguage: language,
            llmPassEnabled: llmPassEnabled,
            llmModel: llmModel,
            summaryType: summaryType,
            micVoiceProcessing: micVoiceProcessing
        )
    }

    private func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try OpenAIKeychain.set(trimmed)
            apiKeyDraft = ""
            hasStoredAPIKey = true
            apiKeySaveError = nil
        } catch {
            apiKeySaveError = "\(error)"
        }
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

    // MARK: - Updates

    private func checkForUpdatesManually() {
        updateCheckState = .checking
        Task {
            if let info = await UpdateChecker.checkForUpdate() {
                updateCheckState = .available(info)
            } else {
                updateCheckState = .upToDate
            }
        }
    }

    private func installUpdate(_ info: UpdateInfo) {
        updateCheckState = .installing
        Task {
            do {
                try await UpdateInstaller.install(info)
                // On success the process is replaced/terminated by
                // UpdateInstaller — this line only runs if that step throws
                // before reaching the relaunch.
            } catch {
                updateCheckState = .failed("\(error)")
            }
        }
    }
}
