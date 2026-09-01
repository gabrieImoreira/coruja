# OpenAI Summary/Title, Ata + Update Popups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Ollama with the OpenAI API for the optional summary/title
pass (adding a user-selectable "ata" vs "resumo por tópico" output), add an
automatic + manual in-app update checker that downloads and installs new
releases, and restyle the meeting-lifecycle prompts to look native
("Apple-style"), including bringing the app forward when a meeting ends.

**Architecture:** Swift Package Manager executable target (`coruja`),
AppKit + SwiftUI hybrid (AppKit shell/menu bar/panels, SwiftUI for the
notes/settings window content). No test target exists yet — this plan adds
one (`corujaTests`) alongside the executable target, using `@testable
import coruja` and a `URLProtocol`-based HTTP mock for network code. No new
runtime dependencies.

**Tech Stack:** Swift 6 tools / Swift 5 language mode, AppKit, SwiftUI,
Foundation (`URLSession`, `Security` framework for Keychain), XCTest.

**Spec:** `docs/superpowers/specs/2026-09-01-openai-ata-update-popups-design.md`

## Global Constraints

- API key lives only in the macOS Keychain (service
  `com.gabrieImoreira.coruja`, account `openai_api_key`) — never in
  `config.json`, never logged.
- `Config.summaryType()` values are exactly `"ata"` and `"topicos"`,
  default `"topicos"`.
- `Config.llmModel()` default changes from `"llama3.1:8b"` to
  `"gpt-4o-mini"`.
- OpenAI Chat Completions endpoint is fixed:
  `https://api.openai.com/v1/chat/completions` — no configurable endpoint
  (unlike Ollama's `llm_endpoint`, which is removed).
- The privacy note in Settings must say plainly that the transcript is sent
  to OpenAI when the pass is enabled — never softened or hidden.
- Automatic update popup never re-prompts for a version the user already
  dismissed (`UserDefaults` key `corujaDismissedUpdateVersion`); the manual
  "Verificar atualizações" button in Settings always ignores that gate.
- The update installer only moves the currently-installed `/Applications/Coruja.app`
  to the Trash after every earlier step (download, unzip, bundle
  validation, `xattr -cr`) has succeeded — never before.
- Popups (meeting detected/ended, update available) share one visual
  component (`NotificationPanel`): `NSVisualEffectView` `.hudWindow`
  material, 14pt continuous corner radius, no system-blue accent on
  buttons.

---

## Task 1: OpenAI API key storage (Keychain)

**Files:**
- Create: `Sources/coruja/OpenAIKeychain.swift`

**Interfaces:**
- Produces: `enum OpenAIKeychain { static func get() -> String?; static func set(_ key: String) throws; static func delete() }`,
  `OpenAIKeychain.KeychainError`

- [ ] **Step 1: Write `OpenAIKeychain.swift`**

```swift
import Foundation
import Security

/// Stores the user's OpenAI API key in the macOS Keychain — never in
/// config.json, unlike every other setting this app persists. A generic
/// password item scoped to this app's bundle identifier; only the Settings
/// UI reads or writes it.
enum OpenAIKeychain {
    private static let service = "com.gabrieImoreira.coruja"
    private static let account = "openai_api_key"

    enum KeychainError: Error, CustomStringConvertible {
        case saveFailed(OSStatus)

        var description: String {
            switch self {
            case .saveFailed(let status):
                return "não foi possível salvar a chave no Keychain (status \(status))"
            }
        }
    }

    static func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete-then-add rather than update: simpler than juggling
        // SecItemUpdate's separate query/attributes-to-change dictionaries
        // for a single-field item like this one.
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds with no errors (no test target exists yet — Keychain
access from an unsigned `swift test` binary can trigger an interactive
permission prompt, so this type is verified manually instead of via
automated test).

- [ ] **Step 3: Manual verification**

In a scratch Swift file or via `swift run coruja doctor` temporarily adding
a print, confirm: `OpenAIKeychain.set("sk-test-123")` then
`OpenAIKeychain.get()` returns `"sk-test-123"`, then `OpenAIKeychain.delete()`
then `OpenAIKeychain.get()` returns `nil`. Remove any temporary test code
before committing.

- [ ] **Step 4: Commit**

```bash
git add Sources/coruja/OpenAIKeychain.swift
git commit -m "Add OpenAIKeychain for storing the OpenAI API key in the macOS Keychain"
```

---

## Task 2: Config changes + test target scaffold

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/coruja/Config.swift`
- Create: `Tests/corujaTests/ConfigTests.swift`

**Interfaces:**
- Consumes: none
- Produces: `Config.summaryType() -> String`, `Config.path: URL` (now
  mutable, for test isolation), `Config.save(...)` gains a `summaryType:
  String` parameter, `Config.llmEndpoint()` is removed, `Config.llmModel()`
  default becomes `"gpt-4o-mini"`.

- [ ] **Step 1: Add the test target to `Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "coruja",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "coruja",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/coruja/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "corujaTests",
            dependencies: ["coruja"]
        ),
    ]
)
```

- [ ] **Step 2: Make `Config.path` overridable for tests**

In `Sources/coruja/Config.swift`, change:

```swift
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/coruja/config.json")
```

to:

```swift
    /// `var`, not `let` — ConfigTests points this at a temp file so tests
    /// never read or write the developer's real ~/.config/coruja/config.json.
    static var path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/coruja/config.json")
```

- [ ] **Step 3: Remove `llmEndpoint()`, update `llmModel()` default, add `summaryType()`**

Replace:

```swift
    /// Ollama model tag. Needs to already be pulled (`ollama pull <tag>`).
    static func llmModel() -> String {
        transcription()?["llm_model"] as? String ?? "llama3.1:8b"
    }

    /// Ollama's local HTTP endpoint.
    static func llmEndpoint() -> URL {
        let raw = transcription()?["llm_endpoint"] as? String ?? "http://localhost:11434"
        return URL(string: raw) ?? URL(string: "http://localhost:11434")!
    }
```

with:

```swift
    /// OpenAI model tag (e.g. "gpt-4o-mini"). Needs a valid API key in the
    /// Keychain (see OpenAIKeychain) — this alone doesn't enable the pass.
    static func llmModel() -> String {
        transcription()?["llm_model"] as? String ?? "gpt-4o-mini"
    }

    /// Which document shape the summary pass produces: "ata" (formal
    /// minutes — pauta/decisões) or "topicos" (detailed topic-by-topic
    /// narrative). See SummaryEngine.SummaryType.
    static func summaryType() -> String {
        transcription()?["summary_type"] as? String ?? "topicos"
    }
```

- [ ] **Step 4: Update the doc comment above `llmPassEnabled()`**

Replace:

```swift
    /// Optional local-LLM pass over the finished transcript (summary + action
    /// items). Off by default — it's an extra local model download/run cost
    /// on top of the transcription engine, and unlike everything else this
    /// app does, its output is *generated* text rather than a direct
    /// transcription, so it should never turn on without the user asking.
    /// Always local (Ollama) — no cloud option, matching every other part of
    /// this app's "nothing leaves the machine" design.
    static func llmPassEnabled() -> Bool {
        transcription()?["llm_pass"] as? Bool ?? false
    }
```

with:

```swift
    /// Optional OpenAI pass over the finished transcript (summary + action
    /// items + title). Off by default — unlike everything else this app
    /// does, its output is *generated* text rather than a direct
    /// transcription, and turning it on sends the transcript to OpenAI —
    /// the one place this app's "nothing leaves the machine" design doesn't
    /// hold. Never turns on without the user asking, and the Settings UI
    /// says so explicitly next to the toggle.
    static func llmPassEnabled() -> Bool {
        transcription()?["llm_pass"] as? Bool ?? false
    }
```

- [ ] **Step 5: Update `save(...)`**

Replace the whole function with:

```swift
    static func save(
        recordingsDir: String,
        transcriptionEnabled: Bool,
        transcriptionEngine: String,
        transcriptionLanguage: String,
        llmPassEnabled: Bool,
        llmModel: String,
        summaryType: String,
        micVoiceProcessing: Bool
    ) {
        var json = load() ?? [:]

        let trimmedDir = recordingsDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDir.isEmpty {
            json.removeValue(forKey: "recordings_dir")
        } else {
            json["recordings_dir"] = trimmedDir
        }
        json["mic_voice_processing"] = micVoiceProcessing

        var t = json["transcription"] as? [String: Any] ?? [:]
        t["enabled"] = transcriptionEnabled
        t["engine"] = transcriptionEngine
        t["language"] = transcriptionLanguage
        t["llm_pass"] = llmPassEnabled
        let trimmedModel = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        t["llm_model"] = trimmedModel.isEmpty ? "gpt-4o-mini" : trimmedModel
        t["summary_type"] = summaryType == "ata" ? "ata" : "topicos"
        json["transcription"] = t

        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: path, options: .atomic)
    }
```

- [ ] **Step 6: Write `Tests/corujaTests/ConfigTests.swift`**

```swift
import XCTest
@testable import coruja

final class ConfigTests: XCTestCase {
    private var tempDir: URL!
    private var originalPath: URL!

    override func setUp() {
        super.setUp()
        originalPath = Config.path
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coruja-config-test-\(UUID().uuidString)", isDirectory: true)
        Config.path = tempDir.appendingPathComponent("config.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        Config.path = originalPath
        super.tearDown()
    }

    func testSummaryTypeDefaultsToTopicos() {
        XCTAssertEqual(Config.summaryType(), "topicos")
    }

    func testLlmModelDefaultsToGpt4oMini() {
        XCTAssertEqual(Config.llmModel(), "gpt-4o-mini")
    }

    func testSaveAndReloadSummaryTypeAndModel() {
        Config.save(
            recordingsDir: "",
            transcriptionEnabled: true,
            transcriptionEngine: "whisper",
            transcriptionLanguage: "pt",
            llmPassEnabled: true,
            llmModel: "gpt-4.1-mini",
            summaryType: "ata",
            micVoiceProcessing: false
        )
        XCTAssertEqual(Config.summaryType(), "ata")
        XCTAssertEqual(Config.llmModel(), "gpt-4.1-mini")
    }

    func testSaveRejectsUnknownSummaryType() {
        Config.save(
            recordingsDir: "",
            transcriptionEnabled: true,
            transcriptionEngine: "whisper",
            transcriptionLanguage: "pt",
            llmPassEnabled: false,
            llmModel: "gpt-4o-mini",
            summaryType: "garbage",
            micVoiceProcessing: false
        )
        XCTAssertEqual(Config.summaryType(), "topicos")
    }
}
```

- [ ] **Step 7: Run the tests**

Run: `swift test --filter ConfigTests`
Expected: 4 tests pass. This is also the first `swift test` invocation in
the project — if it fails to even build, check that `Tests/corujaTests/`
was created in the right place (SwiftPM's default test target path).

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/coruja/Config.swift Tests/corujaTests/ConfigTests.swift
git commit -m "Replace Ollama config with OpenAI model + summary_type; add test target"
```

---

## Task 3: SummaryEngine — OpenAI transport, ata/topicos prompts

**Files:**
- Modify: `Sources/coruja/Transcription/SummaryEngine.swift`
- Create: `Tests/corujaTests/MockURLProtocol.swift`
- Create: `Tests/corujaTests/SummaryEngineTests.swift`

**Interfaces:**
- Consumes: none new
- Produces: `SummaryEngine.SummaryType` (`.ata`, `.topicos`),
  `SummaryEngine.summarize(segments:apiKey:model:summaryType:chunkMinutes:session:)`,
  `SummaryEngine.SummaryError.missingAPIKey`

- [ ] **Step 1: Write the shared HTTP mock**

```swift
// Tests/corujaTests/MockURLProtocol.swift
import Foundation

/// Stubs `URLSession` for tests that would otherwise hit a real network
/// endpoint (OpenAI, GitHub). Set `handler` before making the request;
/// build the session under test with `URLSession.mocked()`.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLSession {
    static func mocked() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
```

- [ ] **Step 2: Rewrite `SummaryEngine.swift`**

```swift
import Foundation

/// Optional OpenAI pass over a finished transcript: either a formal "ata"
/// (pauta + decisões) or a detailed topic-by-topic narrative, plus action
/// items either way. Opt-in (`transcription.llm_pass` in config) — see
/// Config.swift. Sends the transcript to OpenAI when enabled; that's the
/// one place this app's "nothing leaves the machine" design doesn't hold.
///
/// This generates text, unlike the rest of the pipeline which only
/// transcribes what was actually said — so the prompt's non-negotiable rule
/// is not inventing content, not improving grammar, and not including an
/// action item unless it's explicitly there in the transcript. A summary
/// that reads better than the meeting but says something nobody said is
/// worse than no summary.
///
/// Map-reduce over ~10min chunks, not one call over the whole transcript —
/// see the historical note in this file's git history (confirmed live
/// against a real 87min/~11k-word meeting: a single-pass summary lost every
/// domain-specific term from an hour of discussion). Each ~10min chunk is
/// short enough that the model stays grounded in it.
enum SummaryEngine {
    /// Which document shape to produce. See Config.summaryType().
    enum SummaryType: String, Sendable {
        case ata
        case topicos
    }

    struct ActionItem: Codable, Sendable {
        let item: String
        let responsavel: String?
        let prazo: String?
    }

    struct Summary: Codable, Sendable {
        let resumo: String
        let itensDeAcao: [ActionItem]

        enum CodingKeys: String, CodingKey {
            case resumo
            case itensDeAcao = "itens_de_acao"
        }
    }

    struct TimedSegment: Sendable {
        let speaker: String
        let text: String
        let startMs: Int
    }

    enum SummaryError: Error, CustomStringConvertible {
        case emptyTranscript
        case missingAPIKey
        case httpError(Int)
        case unparseable(String)

        var description: String {
            switch self {
            case .emptyTranscript: return "nothing to summarize"
            case .missingAPIKey: return "no OpenAI API key configured"
            case .httpError(let code): return "OpenAI returned HTTP \(code) — check the API key and usage limits"
            case .unparseable(let raw): return "model didn't return valid JSON: \(raw.prefix(200))"
            }
        }
    }

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// - Parameters:
    ///   - segments: transcript segments in chronological order.
    ///   - apiKey: OpenAI API key (see OpenAIKeychain) — throws
    ///     `.missingAPIKey` if empty.
    ///   - chunkMinutes: size of each map step. 10min keeps a real meeting's
    ///     worth of context small enough for the model to stay grounded in,
    ///     without so many chunks that the reduce step loses coherence.
    static func summarize(
        segments: [TimedSegment],
        apiKey: String,
        model: String,
        summaryType: SummaryType,
        chunkMinutes: Double = 10,
        session: URLSession = .shared
    ) async throws -> Summary {
        guard !segments.isEmpty else { throw SummaryError.emptyTranscript }
        guard !apiKey.isEmpty else { throw SummaryError.missingAPIKey }

        let chunkMs = Int(chunkMinutes * 60_000)
        var chunks: [[TimedSegment]] = []
        var current: [TimedSegment] = []
        var chunkStart = segments[0].startMs
        for segment in segments {
            if segment.startMs - chunkStart >= chunkMs, !current.isEmpty {
                chunks.append(current)
                current = []
                chunkStart = segment.startMs
            }
            current.append(segment)
        }
        if !current.isEmpty { chunks.append(current) }

        var partialSummaries: [String] = []
        var actionItems: [ActionItem] = []
        for chunk in chunks {
            let text = chunk.map { "\($0.speaker == "me" ? "Eu" : $0.speaker): \($0.text)" }.joined(separator: "\n")
            let partial = try await summarizeChunk(
                transcriptText: text, apiKey: apiKey, model: model, summaryType: summaryType, session: session
            )
            if !partial.resumo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                partialSummaries.append(partial.resumo)
            }
            actionItems += partial.itensDeAcao
        }

        let finalSummary: String
        if partialSummaries.count <= 1 {
            finalSummary = partialSummaries.first ?? ""
        } else {
            finalSummary = try await reduceSummaries(partialSummaries, apiKey: apiKey, model: model, session: session)
        }

        return Summary(resumo: finalSummary, itensDeAcao: actionItems)
    }

    private static let extractionRules = """
    REGRAS OBRIGATÓRIAS, sem exceção:
    - NÃO invente nenhuma informação que não esteja literalmente no texto — \
    incluindo nomes de pessoas, prazos ou responsáveis. Se o texto não deixar \
    claro quem faria algo, use null em "responsavel".
    - NÃO resuma de forma criativa, não corrija gramática de falas, não \
    complete frases cortadas. Só relate o que foi dito, com os termos \
    específicos usados no texto (nomes de sistemas, campos, processos).
    - "itens_de_acao" é só para COMPROMISSO DE PESSOA — alguém dizendo que \
    VAI fazer algo, ou pedindo explicitamente pra outra pessoa fazer algo \
    ("eu mando o e-mail", "fica pra você verificar isso", "vou perguntar \
    pra fulano"). NÃO é lugar para decisão de design, regra de fluxo ou \
    comportamento do sistema sendo discutido ("o cliente escolhe entre as \
    opções", "listar as apólices para seleção") — isso é conteúdo do \
    resumo, não ação de ninguém. Na dúvida, não inclua. Sem compromisso \
    claro, devolva uma lista vazia — a lista vazia é o resultado esperado \
    na maioria dos trechos, não uma falha.
    """

    private static func summarizeChunk(
        transcriptText: String,
        apiKey: String,
        model: String,
        summaryType: SummaryType,
        session: URLSession
    ) async throws -> Summary {
        let shapeInstructions: String
        switch summaryType {
        case .topicos:
            shapeInstructions = """
            Responda em JSON com exatamente este formato:
            {
              "resumo": "## Tópicos\\n\\n### <nome do tópico 1>\\n<2 a 4 frases sobre o que foi dito>\\n\\n### <nome do tópico 2>\\n...",
              "itens_de_acao": [
                {"item": "descrição da ação", "responsavel": "nome citado ou null", "prazo": "prazo citado ou null"}
              ]
            }
            Liste só os tópicos realmente discutidos NESTE trecho — pode ser um só.
            """
        case .ata:
            shapeInstructions = """
            Responda em JSON com exatamente este formato:
            {
              "resumo": "## Pauta\\n- <tópico abordado neste trecho>\\n\\n## Decisões\\n- <decisão tomada, ou omita esta seção se nenhuma>",
              "itens_de_acao": [
                {"item": "descrição da ação", "responsavel": "nome citado ou null", "prazo": "prazo citado ou null"}
              ]
            }
            """
        }

        let prompt = """
        Você recebe abaixo a transcrição de um trecho de uma reunião de trabalho, em português.

        \(extractionRules)

        \(shapeInstructions)

        TRECHO DA TRANSCRIÇÃO:
        \(transcriptText)
        """
        return try await callOpenAI(prompt: prompt, apiKey: apiKey, model: model, session: session)
    }

    private static func reduceSummaries(
        _ partials: [String],
        apiKey: String,
        model: String,
        session: URLSession
    ) async throws -> String {
        let bulletList = partials.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n\n")
        let prompt = """
        Abaixo estão resumos de trechos sucessivos de UMA MESMA reunião, em ordem \
        cronológica, cada um já em Markdown com suas próprias seções (##, ###). \
        Combine-os num único documento coeso, preservando essa estrutura de seções.

        REGRAS OBRIGATÓRIAS:
        - NÃO invente nada que não esteja nos resumos abaixo.
        - NÃO remova termos técnicos específicos (nomes de sistemas, processos, campos).
        - Elimine só repetição literal entre trechos adjacentes; mantenha os assuntos distintos.
        - Mantenha os cabeçalhos Markdown (##, ###) como estão nos trechos.

        Responda em JSON com exatamente este formato:
        {"resumo": "o documento combinado, em Markdown"}

        TRECHOS:
        \(bulletList)
        """
        struct Reduced: Codable { let resumo: String }
        let data = try await callOpenAIRaw(prompt: prompt, apiKey: apiKey, model: model, session: session)
        guard let reduced = try? JSONDecoder().decode(Reduced.self, from: data) else {
            // Reduce failing shouldn't lose the map step's work — fall back to
            // the partial summaries joined as-is.
            return partials.joined(separator: "\n\n")
        }
        return reduced.resumo
    }

    private static func callOpenAI(
        prompt: String, apiKey: String, model: String, session: URLSession
    ) async throws -> Summary {
        let data = try await callOpenAIRaw(prompt: prompt, apiKey: apiKey, model: model, session: session)
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else {
            throw SummaryError.unparseable(String(data: data, encoding: .utf8) ?? "")
        }
        return summary
    }

    /// Raw call to OpenAI's Chat Completions API, returning the model's
    /// JSON content (itself a JSON string inside `choices[0].message.content`)
    /// as `Data` for the caller to decode into whatever shape it asked for.
    private static func callOpenAIRaw(
        prompt: String, apiKey: String, model: String, session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "response_format": ["type": "json_object"],
            "messages": [["role": "user", "content": prompt]],
        ])
        request.timeoutInterval = 300

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SummaryError.httpError(code)
        }

        struct OpenAIResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        guard
            let parsed = try? JSONDecoder().decode(OpenAIResponse.self, from: data),
            let content = parsed.choices.first?.message.content,
            let contentData = content.data(using: .utf8)
        else {
            throw SummaryError.unparseable(String(data: data, encoding: .utf8) ?? "")
        }
        return contentData
    }
}
```

- [ ] **Step 3: Write `Tests/corujaTests/SummaryEngineTests.swift`**

```swift
import XCTest
@testable import coruja

final class SummaryEngineTests: XCTestCase {
    private func openAIResponse(content: String) -> Data {
        let payload: [String: Any] = [
            "choices": [["message": ["content": content]]]
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func testMissingAPIKeyThrows() async {
        let segments = [SummaryEngine.TimedSegment(speaker: "me", text: "oi", startMs: 0)]
        do {
            _ = try await SummaryEngine.summarize(
                segments: segments, apiKey: "", model: "gpt-4o-mini", summaryType: .topicos
            )
            XCTFail("expected missingAPIKey")
        } catch SummaryEngine.SummaryError.missingAPIKey {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEmptyTranscriptThrows() async {
        do {
            _ = try await SummaryEngine.summarize(
                segments: [], apiKey: "sk-test", model: "gpt-4o-mini", summaryType: .topicos
            )
            XCTFail("expected emptyTranscript")
        } catch SummaryEngine.SummaryError.emptyTranscript {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSingleChunkReturnsChunkSummaryDirectly() async throws {
        let content = "{\"resumo\": \"## Tópicos\\n\\n### Pagamentos\\ndiscutido X\", \"itens_de_acao\": []}"
        MockURLProtocol.handler = { [weak self] _ in (200, self!.openAIResponse(content: content)) }
        let segments = [SummaryEngine.TimedSegment(speaker: "me", text: "falamos de pagamentos", startMs: 0)]

        let summary = try await SummaryEngine.summarize(
            segments: segments, apiKey: "sk-test", model: "gpt-4o-mini",
            summaryType: .topicos, session: .mocked()
        )

        XCTAssertTrue(summary.resumo.contains("Pagamentos"))
        XCTAssertTrue(summary.itensDeAcao.isEmpty)
    }

    func testActionItemsAreCollectedAcrossChunks() async throws {
        let content = "{\"resumo\": \"## Pauta\\n- x\", \"itens_de_acao\": [{\"item\": \"mandar email\", \"responsavel\": \"Ana\", \"prazo\": null}]}"
        MockURLProtocol.handler = { [weak self] _ in (200, self!.openAIResponse(content: content)) }
        let segments = [SummaryEngine.TimedSegment(speaker: "me", text: "eu mando o email", startMs: 0)]

        let summary = try await SummaryEngine.summarize(
            segments: segments, apiKey: "sk-test", model: "gpt-4o-mini",
            summaryType: .ata, session: .mocked()
        )

        XCTAssertEqual(summary.itensDeAcao.count, 1)
        XCTAssertEqual(summary.itensDeAcao[0].responsavel, "Ana")
    }

    func testHTTPErrorIsSurfaced() async {
        MockURLProtocol.handler = { _ in (401, Data()) }
        let segments = [SummaryEngine.TimedSegment(speaker: "me", text: "oi", startMs: 0)]
        do {
            _ = try await SummaryEngine.summarize(
                segments: segments, apiKey: "sk-bad", model: "gpt-4o-mini",
                summaryType: .topicos, session: .mocked()
            )
            XCTFail("expected httpError")
        } catch SummaryEngine.SummaryError.httpError(let code) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter SummaryEngineTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/coruja/Transcription/SummaryEngine.swift Tests/corujaTests/MockURLProtocol.swift Tests/corujaTests/SummaryEngineTests.swift
git commit -m "Switch SummaryEngine from Ollama to OpenAI; add ata/topicos output shapes"
```

---

## Task 4: TitleEngine — OpenAI transport

**Files:**
- Modify: `Sources/coruja/Transcription/TitleEngine.swift`
- Create: `Tests/corujaTests/TitleEngineTests.swift`

**Interfaces:**
- Consumes: `MockURLProtocol`, `URLSession.mocked()` (from Task 3)
- Produces: `TitleEngine.generate(segments:root:excluding:apiKey:model:session:)`,
  `TitleEngine.TitleError.missingAPIKey`

- [ ] **Step 1: Update the doc comment and signature in `TitleEngine.swift`**

Replace lines 1–68 (imports through `generate`'s signature and body) with:

```swift
import Foundation

/// Generates a short, human-readable title for a finished session, so the
/// notes window doesn't have to lean on a bare timestamp. Two steps:
///
/// 1. A deterministic TF-IDF pass over this session's words against the
///    user's other sessions (no LLM) — picks out words that are unusually
///    frequent HERE compared to elsewhere, which is what actually
///    distinguishes one meeting from another. Raw word frequency alone
///    doesn't: tested live against 11 real recordings and it just surfaces
///    whatever domain jargon this user repeats in nearly every meeting
///    ("tem", "está", generic verbs, or for this user "sinistro",
///    "reembolso"). TF-IDF against the corpus discounts exactly that.
/// 2. One small OpenAI call turns the resulting keywords into a short
///    phrase — the keywords alone read as a tag list, not a title.
///
/// Piggybacks on the same opt-in `llm_pass` config as SummaryEngine (see
/// Config.swift): tested the keyword step without an LLM afterward and it
/// wasn't good enough to ship as the default, so there's no LLM-free path
/// here. Without a configured API key, a session simply keeps showing its
/// timestamp.
///
/// Titles are stored per-session in `.title` (plain text, one line) — never
/// the folder name itself (RecordingSession keeps that timestamp-only on
/// purpose) — and are user-editable from the notes window; an edit just
/// overwrites this file.
enum TitleEngine {
    static let titleFileName = ".title"

    enum TitleError: Error, CustomStringConvertible {
        case noKeywords
        case missingAPIKey
        case httpError(Int)
        case empty

        var description: String {
            switch self {
            case .noKeywords: return "not enough text to extract keywords from"
            case .missingAPIKey: return "no OpenAI API key configured"
            case .httpError(let code): return "OpenAI returned HTTP \(code) — check the API key and usage limits"
            case .empty: return "model returned an empty title"
            }
        }
    }

    /// - Parameters:
    ///   - segments: this session's transcript segments (speaker, text).
    ///   - root: recordings root, scanned for sibling sessions' `.transcript.json`
    ///     to build the TF-IDF corpus.
    ///   - own: this session's directory — excluded when scanning `root`.
    ///   - apiKey: OpenAI API key (see OpenAIKeychain) — throws
    ///     `.missingAPIKey` if empty.
    static func generate(
        segments: [(speaker: String, text: String)],
        root: URL,
        excluding own: URL,
        apiKey: String,
        model: String,
        session: URLSession = .shared
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw TitleError.missingAPIKey }

        let ownWords = wordCounts(segments.map(\.text))
        guard !ownWords.isEmpty else { throw TitleError.noKeywords }

        let corpus = corpusWordCounts(root: root, excluding: own)
        let topKeywords = keywords(own: ownWords, corpus: corpus)
        guard !topKeywords.isEmpty else { throw TitleError.noKeywords }

        let sample = segments.prefix(8)
            .map { "\($0.speaker == "me" ? "Eu" : $0.speaker): \($0.text)" }
            .joined(separator: "\n")
        let title = try await askOpenAI(
            keywords: topKeywords, sample: sample, apiKey: apiKey, model: model, session: session
        )
        guard !title.isEmpty else { throw TitleError.empty }
        return title
    }
```

Leave the TF-IDF section (`stopwords`, `wordCounts`, `MiniTranscript`,
`corpusWordCounts`, `keywords`) exactly as-is — nothing there talks to
Ollama.

- [ ] **Step 2: Replace `askOllama` with `askOpenAI`**

Replace the `// MARK: - Ollama` section at the bottom of the file with:

```swift
    // MARK: - OpenAI

    private static func askOpenAI(
        keywords: [String], sample: String, apiKey: String, model: String, session: URLSession
    ) async throws -> String {
        let prompt = """
        Palavras-chave extraídas de uma reunião (ordem de relevância): \(keywords.joined(separator: ", "))

        Trecho do início da reunião (contexto, pode ignorar saudações):
        \(sample)

        Gere um título curto (3 a 6 palavras, em português) que descreva o \
        assunto principal desta reunião, baseado nas palavras-chave acima. \
        Responda APENAS o título, sem aspas, sem explicação.
        """
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0.3,
            "messages": [["role": "user", "content": prompt]],
        ])
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TitleError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        struct OpenAIResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        guard
            let parsed = try? JSONDecoder().decode(OpenAIResponse.self, from: data),
            var title = parsed.choices.first?.message.content
                .trimmingCharacters(in: .whitespacesAndNewlines) as String?
        else {
            return ""
        }
        // The model sometimes wraps the title in quotes or adds a trailing
        // line despite the "only the title" instruction — strip both.
        if let firstLine = title.split(separator: "\n", maxSplits: 1).first { title = String(firstLine) }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
        return title
    }
}
```

- [ ] **Step 3: Write `Tests/corujaTests/TitleEngineTests.swift`**

```swift
import XCTest
@testable import coruja

final class TitleEngineTests: XCTestCase {
    private func openAIResponse(content: String) -> Data {
        let payload: [String: Any] = ["choices": [["message": ["content": content]]]]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func testMissingAPIKeyThrows() async {
        do {
            _ = try await TitleEngine.generate(
                segments: [(speaker: "me", text: "falamos de pagamentos e reembolso")],
                root: FileManager.default.temporaryDirectory,
                excluding: FileManager.default.temporaryDirectory,
                apiKey: "", model: "gpt-4o-mini"
            )
            XCTFail("expected missingAPIKey")
        } catch TitleEngine.TitleError.missingAPIKey {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStripsQuotesAndExtraLines() async throws {
        MockURLProtocol.handler = { [weak self] _ in
            (200, self!.openAIResponse(content: "\"Reembolso de sinistro\"\nnota extra"))
        }
        let title = try await TitleEngine.generate(
            segments: [(speaker: "me", text: "vamos falar do reembolso do sinistro hoje")],
            root: FileManager.default.temporaryDirectory,
            excluding: FileManager.default.temporaryDirectory,
            apiKey: "sk-test", model: "gpt-4o-mini", session: .mocked()
        )
        XCTAssertEqual(title, "Reembolso de sinistro")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TitleEngineTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/coruja/Transcription/TitleEngine.swift Tests/corujaTests/TitleEngineTests.swift
git commit -m "Switch TitleEngine from Ollama to OpenAI"
```

---

## Task 5: Wire OpenAI key + summary type into TranscriptionCoordinator and BenchSummary

**Files:**
- Modify: `Sources/coruja/Transcription/TranscriptionCoordinator.swift`
- Modify: `Sources/coruja/BenchSummary.swift`

**Interfaces:**
- Consumes: `OpenAIKeychain.get()` (Task 1), `SummaryEngine.summarize(...)`
  and `TitleEngine.generate(...)` new signatures (Tasks 3–4),
  `Config.summaryType()` (Task 2)
- Produces: `TranscriptionCoordinator.renderedSummary(_:type:)` (adds a
  `type` parameter)

- [ ] **Step 1: Update `runSummary` in `TranscriptionCoordinator.swift`**

Replace:

```swift
    /// Opt-in local-LLM pass (see Config.llmPassEnabled / SummaryEngine).
    /// A failure here (Ollama not running, model not pulled, bad JSON back)
    /// is logged and otherwise ignored — the transcript is already written
    /// and is the thing that matters; the summary is a bonus.
    private func runSummary(for segments: [Transcript.Segment], in dir: URL) async {
        let timed = segments.map {
            SummaryEngine.TimedSegment(speaker: $0.speaker, text: $0.text, startMs: $0.start_ms)
        }
        do {
            let summary = try await SummaryEngine.summarize(
                segments: timed,
                model: Config.llmModel(),
                endpoint: Config.llmEndpoint()
            )
            try Self.renderedSummary(summary).write(
                to: dir.appendingPathComponent(Self.summaryMDFileName),
                atomically: true, encoding: .utf8
            )
            log(dir, "summary written — \(summary.itensDeAcao.count) action item(s)")
        } catch {
            log(dir, "summary skipped: \(error)")
        }
    }
```

with:

```swift
    /// Opt-in OpenAI pass (see Config.llmPassEnabled / SummaryEngine). A
    /// failure here (no API key, bad response, rate limit) is logged and
    /// otherwise ignored — the transcript is already written and is the
    /// thing that matters; the summary is a bonus.
    private func runSummary(for segments: [Transcript.Segment], in dir: URL) async {
        guard let apiKey = OpenAIKeychain.get() else {
            log(dir, "summary skipped: no OpenAI API key configured")
            return
        }
        let type = SummaryEngine.SummaryType(rawValue: Config.summaryType()) ?? .topicos
        let timed = segments.map {
            SummaryEngine.TimedSegment(speaker: $0.speaker, text: $0.text, startMs: $0.start_ms)
        }
        do {
            let summary = try await SummaryEngine.summarize(
                segments: timed,
                apiKey: apiKey,
                model: Config.llmModel(),
                summaryType: type
            )
            try Self.renderedSummary(summary, type: type).write(
                to: dir.appendingPathComponent(Self.summaryMDFileName),
                atomically: true, encoding: .utf8
            )
            log(dir, "summary written (\(type.rawValue)) — \(summary.itensDeAcao.count) action item(s)")
        } catch {
            log(dir, "summary skipped: \(error)")
        }
    }
```

- [ ] **Step 2: Update `runTitle`**

Replace:

```swift
    /// Opt-in, same as runSummary — see TitleEngine. A failure here (Ollama
    /// down, not enough text, bad response) just leaves `.title` unwritten;
    /// the session falls back to showing its timestamp, same as today.
    private func runTitle(for segments: [Transcript.Segment], in dir: URL) async {
        let simplified = segments.map { (speaker: $0.speaker, text: $0.text) }
        do {
            let title = try await TitleEngine.generate(
                segments: simplified,
                root: dir.deletingLastPathComponent(),
                excluding: dir,
                model: Config.llmModel(),
                endpoint: Config.llmEndpoint()
            )
            try title.write(
                to: dir.appendingPathComponent(TitleEngine.titleFileName),
                atomically: true, encoding: .utf8
            )
            log(dir, "title: \(title)")
        } catch {
            log(dir, "title skipped: \(error)")
        }
    }
```

with:

```swift
    /// Opt-in, same as runSummary — see TitleEngine. A failure here (no API
    /// key, not enough text, bad response) just leaves `.title` unwritten;
    /// the session falls back to showing its timestamp, same as today.
    private func runTitle(for segments: [Transcript.Segment], in dir: URL) async {
        guard let apiKey = OpenAIKeychain.get() else {
            log(dir, "title skipped: no OpenAI API key configured")
            return
        }
        let simplified = segments.map { (speaker: $0.speaker, text: $0.text) }
        do {
            let title = try await TitleEngine.generate(
                segments: simplified,
                root: dir.deletingLastPathComponent(),
                excluding: dir,
                apiKey: apiKey,
                model: Config.llmModel()
            )
            try title.write(
                to: dir.appendingPathComponent(TitleEngine.titleFileName),
                atomically: true, encoding: .utf8
            )
            log(dir, "title: \(title)")
        } catch {
            log(dir, "title skipped: \(error)")
        }
    }
```

- [ ] **Step 3: Update `renderedSummary`**

Replace:

```swift
    private static func renderedSummary(_ summary: SummaryEngine.Summary) -> String {
        var lines = ["## Resumo", "", summary.resumo, ""]
        if !summary.itensDeAcao.isEmpty {
            lines.append("## Itens de ação")
            lines.append("")
            for item in summary.itensDeAcao {
                var line = "- \(item.item)"
                if let responsavel = item.responsavel { line += " — **\(responsavel)**" }
                if let prazo = item.prazo { line += " (prazo: \(prazo))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
```

with:

```swift
    /// `summary.resumo` already contains its own Markdown sub-headings
    /// (## Tópicos / ### <topic> for `.topicos`, ## Pauta / ## Decisões for
    /// `.ata`) — this just adds the document-level H1 and, if any, the
    /// action items section.
    private static func renderedSummary(_ summary: SummaryEngine.Summary, type: SummaryEngine.SummaryType) -> String {
        let heading = type == .ata ? "# Ata da reunião" : "# Resumo"
        var lines = [heading, "", summary.resumo, ""]
        if !summary.itensDeAcao.isEmpty {
            lines.append("## Itens de ação")
            lines.append("")
            for item in summary.itensDeAcao {
                var line = "- \(item.item)"
                if let responsavel = item.responsavel { line += " — **\(responsavel)**" }
                if let prazo = item.prazo { line += " (prazo: \(prazo))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
```

- [ ] **Step 4: Update `BenchSummary.swift`**

Replace the body of `Summarize.runSummary(dir:)` from the `FileHandle.standardError.write` line through the end with:

```swift
        guard let apiKey = OpenAIKeychain.get() else {
            FileHandle.standardError.write(Data("no OpenAI API key configured (see Settings)\n".utf8))
            throw SummaryEngine.SummaryError.missingAPIKey
        }
        let type = SummaryEngine.SummaryType(rawValue: Config.summaryType()) ?? .topicos
        FileHandle.standardError.write(Data("calling OpenAI (\(Config.llmModel()), \(type.rawValue))...\n".utf8))
        let summary = try await SummaryEngine.summarize(
            segments: timed,
            apiKey: apiKey,
            model: Config.llmModel(),
            summaryType: type
        )

        let heading = type == .ata ? "# Ata da reunião" : "# Resumo"
        var lines = [heading, "", summary.resumo, ""]
        if !summary.itensDeAcao.isEmpty {
            lines.append("## Itens de ação")
            lines.append("")
            for item in summary.itensDeAcao {
                var line = "- \(item.item)"
                if let r = item.responsavel { line += " — **\(r)**" }
                if let p = item.prazo { line += " (prazo: \(p))" }
                lines.append(line)
            }
        }
        let rendered = lines.joined(separator: "\n")
        try rendered.write(to: dir.appendingPathComponent("summary-test.md"), atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("wrote \(dir.appendingPathComponent("summary-test.md").path)\n".utf8))
        print(rendered)
    }
}
```

Also update the doc comment at the top of the file (the one saying "local-LLM
summary pass" and "Ollama setup") to say "OpenAI summary pass" and "OpenAI
API key setup" instead — same sentence shape, new provider name.

- [ ] **Step 5: Build**

Run: `swift build`
Expected: builds cleanly — no remaining references to `Config.llmEndpoint()`
anywhere (grep to confirm: `grep -rn "llmEndpoint" Sources/` should return
nothing).

- [ ] **Step 6: Commit**

```bash
git add Sources/coruja/Transcription/TranscriptionCoordinator.swift Sources/coruja/BenchSummary.swift
git commit -m "Wire OpenAI key + summary type through TranscriptionCoordinator and BenchSummary"
```

---

## Task 6: Settings UI — OpenAI key, document type, privacy note

**Files:**
- Modify: `Sources/coruja/UI/SettingsRootView.swift`

**Interfaces:**
- Consumes: `OpenAIKeychain.get()/set()/delete()` (Task 1),
  `Config.summaryType()` (Task 2), `Config.save(...)` new signature (Task 2)

- [ ] **Step 1: Replace the state properties**

Replace:

```swift
    @State private var llmPassEnabled = false
    @State private var llmModel = "llama3.1:8b"
    @State private var ollamaStatus: OllamaStatus = .checking

    private enum OllamaStatus {
        case checking, ok, notRunning, modelMissing
    }
```

with:

```swift
    @State private var llmPassEnabled = false
    @State private var llmModel = "gpt-4o-mini"
    @State private var summaryType = "topicos"
    @State private var apiKeyDraft = ""
    @State private var hasStoredAPIKey = false
    @State private var apiKeySaveError: String?
```

- [ ] **Step 2: Replace the "Resumo e título automático" section**

Replace:

```swift
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
                                .onSubmit { save(); checkOllama() }
                        }
                        ollamaStatusRow
                    }
                }
```

with:

```swift
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
```

- [ ] **Step 3: Remove the Ollama status check methods**

Delete the entire `// MARK: - Ollama status` section: `ollamaStatusRow`,
`checkOllama()`, and `probeOllama(endpoint:model:)`.

- [ ] **Step 4: Update `onChange` handlers, `onAppear`, `load()`, and `save()`**

Replace:

```swift
        .onChange(of: llmPassEnabled) { _, enabled in
            save()
            if enabled { checkOllama() }
        }
```

with:

```swift
        .onChange(of: llmPassEnabled) { _, _ in save() }
        .onChange(of: summaryType) { _, _ in save() }
```

Replace:

```swift
        .onAppear {
            load()
            if llmPassEnabled { checkOllama() }
        }
```

with:

```swift
        .onAppear(perform: load)
```

Replace:

```swift
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
```

with:

```swift
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
```

- [ ] **Step 5: Build and manually verify**

Run: `swift build`
Expected: builds cleanly.

Use the `run` skill (or `swift run coruja run`) to launch the app, open
Settings, and confirm: the "Resumo e título automático" section shows the
privacy note, the API key field saves and flips the status dot to green,
the document type picker persists across reopening Settings, and the model
field defaults to `gpt-4o-mini`.

- [ ] **Step 6: Commit**

```bash
git add Sources/coruja/UI/SettingsRootView.swift
git commit -m "Settings: OpenAI API key, document type picker, privacy note (drop Ollama status)"
```

---

## Task 7: NotificationPanel (restyled popup) + meeting prompts + foreground on meeting-ended

**Files:**
- Create: `Sources/coruja/UI/NotificationPanel.swift`
- Delete: `Sources/coruja/UI/MeetingPromptWindow.swift`
- Modify: `Sources/coruja/Coruja.swift`

**Interfaces:**
- Produces: `NotificationPanel` (`show(icon:title:message:actionTitle:ignoreTitle:position:autoDismiss:onAction:onIgnore:)`),
  `NotificationPanel.Position` (`.topRight(of:)`, `.bottomRightOfScreen`)

- [ ] **Step 1: Write `NotificationPanel.swift`**

```swift
import AppKit

/// Small non-activating notification-style panel, shared by every prompt
/// coruja shows unprompted: "record this meeting?", "stop recording?", and
/// "update available". Same shape (icon + title + body + up to two
/// buttons, vibrancy background, rounded corners), different content/
/// position per caller. AppController keeps one instance per logical
/// notification stream (meeting prompts vs. the update prompt) rather than
/// sharing a single instance across all three, since a meeting prompt and
/// the update prompt could plausibly be relevant at the same time.
@MainActor
final class NotificationPanel: NSObject {
    enum Position {
        /// Top-right of `window`'s frame, or the main screen if `window` is
        /// nil or not currently on screen.
        case topRight(of: NSWindow?)
        case bottomRightOfScreen
    }

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var onAction: (() -> Void)?
    private var onIgnore: (() -> Void)?

    private static let width: CGFloat = 320
    private static let height: CGFloat = 104

    /// - Parameters:
    ///   - autoDismiss: seconds before the panel auto-dismisses as "ignore",
    ///     or nil to never auto-dismiss (used for the update prompt — a
    ///     decision that consequential shouldn't disappear unattended).
    func show(
        icon: String,
        title: String,
        message: String,
        actionTitle: String,
        ignoreTitle: String = "Ignorar",
        position: Position,
        autoDismiss: TimeInterval? = 25,
        onAction: @escaping () -> Void,
        onIgnore: @escaping () -> Void
    ) {
        dismiss(fired: false) // replace any prompt already showing on this instance
        self.onAction = onAction
        self.onIgnore = onIgnore

        let width = Self.width, height = Self.height
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let iconView = NSImageView(frame: NSRect(x: 16, y: height - 46, width: 22, height: 22))
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        iconView.contentTintColor = .labelColor
        effect.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 48, y: height - 44, width: width - 64, height: 18)
        effect.addSubview(titleLabel)

        let messageLabel = NSTextField(labelWithString: message)
        messageLabel.font = .systemFont(ofSize: 11.5)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        messageLabel.frame = NSRect(x: 48, y: height - 74, width: width - 64, height: 28)
        effect.addSubview(messageLabel)

        // Deliberately no `keyEquivalent = "\r"` on the action button — that
        // would make AppKit paint it as the window's default button (system
        // blue), which clashes with the rest of the app's monochrome UI.
        let actionButton = NSButton(title: actionTitle, target: self, action: #selector(actionTapped))
        actionButton.bezelStyle = .rounded
        actionButton.frame = NSRect(x: width - 92, y: 14, width: 78, height: 26)
        effect.addSubview(actionButton)

        let ignoreButton = NSButton(title: ignoreTitle, target: self, action: #selector(ignoreTapped))
        ignoreButton.bezelStyle = .rounded
        ignoreButton.frame = NSRect(x: width - 180, y: 14, width: 80, height: 26)
        effect.addSubview(ignoreButton)

        panel.contentView = effect
        panel.setFrameOrigin(origin(for: position, size: NSSize(width: width, height: height)))
        panel.orderFrontRegardless()
        self.panel = panel

        if let autoDismiss {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismiss, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(fired: true) }
            }
        }
    }

    @objc private func actionTapped() {
        let action = onAction
        dismiss(fired: false)
        action?()
    }

    @objc private func ignoreTapped() {
        dismiss(fired: true)
    }

    private func dismiss(fired: Bool) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.close()
        panel = nil
        if fired {
            let action = onIgnore
            onAction = nil
            onIgnore = nil
            action?()
        } else {
            onAction = nil
            onIgnore = nil
        }
    }

    private func origin(for position: Position, size: NSSize) -> NSPoint {
        let margin: CGFloat = 12
        switch position {
        case .topRight(let window):
            let frame = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: frame.maxX - size.width - margin, y: frame.maxY - size.height - margin)
        case .bottomRightOfScreen:
            let frame = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: frame.maxX - size.width - margin, y: frame.minY + margin)
        }
    }
}
```

- [ ] **Step 2: Delete `MeetingPromptWindow.swift`**

```bash
git rm Sources/coruja/UI/MeetingPromptWindow.swift
```

- [ ] **Step 3: Update `Coruja.swift`'s meeting prompt integration**

Replace:

```swift
    private let meetingDetector = MeetingDetector()
    private let meetingPrompt = MeetingPromptWindow()
```

with:

```swift
    private let meetingDetector = MeetingDetector()
    private let meetingPrompt = NotificationPanel()
```

Replace `handleMeetingDetected`:

```swift
    private func handleMeetingDetected(_ url: String) {
        guard session == nil else { return } // already recording something
        meetingPrompt.show(
            message: "Reunião detectada no Chrome.\nGravar com a coruja?",
            actionTitle: "Gravar",
            onAction: { [weak self] in
                self?.meetingRecordingURL = url
                self?.startSession()
            },
            onIgnore: {}
        )
    }
```

with:

```swift
    private func handleMeetingDetected(_ url: String) {
        guard session == nil else { return } // already recording something
        meetingPrompt.show(
            icon: "video.fill",
            title: "Reunião detectada",
            message: "Gravar com a coruja?",
            actionTitle: "Gravar",
            position: .topRight(of: nil),
            onAction: { [weak self] in
                self?.meetingRecordingURL = url
                self?.startSession()
            },
            onIgnore: {}
        )
    }
```

Replace `handleMeetingEnded`:

```swift
    /// Only for a recording coruja itself started via the meeting-detected
    /// prompt above (see meetingRecordingURL) — a manually started recording
    /// is never touched by a Chrome tab closing, same rule as before this
    /// existed, just surfaced now instead of silently auto-stopping.
    private func handleMeetingEnded(_ url: String) {
        guard meetingRecordingURL == url, session != nil else { return }
        meetingRecordingURL = nil
        meetingPrompt.show(
            message: "A reunião parece ter terminado.\nParar a gravação?",
            actionTitle: "Parar",
            ignoreTitle: "Continuar",
            onAction: { [weak self] in self?.stopSession() },
            onIgnore: {}
        )
    }
```

with:

```swift
    /// Only for a recording coruja itself started via the meeting-detected
    /// prompt above (see meetingRecordingURL) — a manually started recording
    /// is never touched by a Chrome tab closing, same rule as before this
    /// existed, just surfaced now instead of silently auto-stopping. Brings
    /// the app forward first (openNotes()) — unlike the "meeting detected"
    /// prompt, which never steals focus from the meeting window, "your
    /// meeting just ended" is exactly the moment the user is meant to look
    /// at coruja.
    private func handleMeetingEnded(_ url: String) {
        guard meetingRecordingURL == url, session != nil else { return }
        meetingRecordingURL = nil
        openNotes()
        meetingPrompt.show(
            icon: "stop.circle",
            title: "Reunião encerrada",
            message: "Parar a gravação?",
            actionTitle: "Parar",
            ignoreTitle: "Continuar",
            position: .topRight(of: notesWindow?.window),
            onAction: { [weak self] in self?.stopSession() },
            onIgnore: {}
        )
    }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 5: Manual verification**

Using the `run` skill: trigger a meeting-detected prompt (open a Google
Meet URL pattern in Chrome, e.g. navigate to `https://meet.google.com/abc-defg-hij`)
and confirm the new vibrancy-styled panel appears top-right of the screen.
Start a recording via the prompt, then close the Meet tab, and confirm the
notes window comes to the foreground and the "Parar a gravação?" panel
appears top-right of that window (not the screen) when the window isn't
maximized to the full screen width.

- [ ] **Step 6: Commit**

```bash
git add -A Sources/coruja/UI/NotificationPanel.swift Sources/coruja/Coruja.swift
git commit -m "Restyle meeting prompts as NotificationPanel; foreground app on meeting-ended"
```

---

## Task 8: UpdateChecker — GitHub release check, semver compare, dismissal

**Files:**
- Create: `Sources/coruja/UpdateChecker.swift`
- Create: `Tests/corujaTests/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: `MockURLProtocol`, `URLSession.mocked()` (Task 3)
- Produces: `UpdateInfo`, `UpdateChecker.checkForUpdate(currentVersion:session:) async -> UpdateInfo?`,
  `UpdateChecker.isNewer(_:than:) -> Bool`, `UpdateChecker.isDismissed(_:defaults:) -> Bool`,
  `UpdateChecker.dismiss(_:defaults:)`

- [ ] **Step 1: Write `UpdateChecker.swift`**

```swift
import Foundation

struct UpdateInfo: Equatable, Sendable {
    let version: String
    let zipURL: URL
    let releaseNotesURL: URL
}

/// Checks GitHub Releases for a newer coruja version than the one running.
/// No auth (public API, 60 req/h per IP — plenty for a check on launch plus
/// once a day) and no external dependency (Foundation's URLSession/JSONDecoder
/// only). See UpdateInstaller for what happens when the user accepts.
enum UpdateChecker {
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/gabrieImoreira/coruja/releases/latest"
    )!
    private static let dismissedVersionKey = "corujaDismissedUpdateVersion"

    /// Returns the latest release's info if it's newer than `currentVersion`,
    /// nil otherwise — including on any network or parse failure. A failed
    /// check is silent for the automatic path; callers that need to
    /// distinguish "up to date" from "check failed" (the manual Settings
    /// button) should treat `nil` as "nothing to report" either way, since
    /// there's no actionable difference for the user.
    static func checkForUpdate(
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
        session: URLSession = .shared
    ) async -> UpdateInfo? {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }

        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Release: Decodable { let tag_name: String; let html_url: String; let assets: [Asset] }

        guard
            let release = try? JSONDecoder().decode(Release.self, from: data),
            let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
            let zipURL = URL(string: asset.browser_download_url),
            let notesURL = URL(string: release.html_url)
        else { return nil }

        let remoteVersion = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard isNewer(remoteVersion, than: currentVersion) else { return nil }
        return UpdateInfo(version: remoteVersion, zipURL: zipURL, releaseNotesURL: notesURL)
    }

    /// True if `remote` is a strictly greater "major.minor.patch" version
    /// than `current`. Missing or non-numeric components compare as 0 —
    /// good enough for this app's plain semver tags (no pre-release suffixes).
    static func isNewer(_ remote: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let r = parts(remote), c = parts(current)
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }

    // MARK: - Dismissal (automatic-check path only — see Settings for the manual check)

    static func isDismissed(_ version: String, defaults: UserDefaults = .standard) -> Bool {
        guard let dismissed = defaults.string(forKey: dismissedVersionKey) else { return false }
        return !isNewer(version, than: dismissed)
    }

    static func dismiss(_ version: String, defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: dismissedVersionKey)
    }
}
```

- [ ] **Step 2: Write `Tests/corujaTests/UpdateCheckerTests.swift`**

```swift
import XCTest
@testable import coruja

final class UpdateCheckerTests: XCTestCase {
    private func releasePayload(tag: String) -> Data {
        let payload: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/gabrieImoreira/coruja/releases/tag/\(tag)",
            "assets": [
                ["name": "coruja-\(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)-macos.zip",
                 "browser_download_url": "https://example.com/coruja.zip"]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func testIsNewerBasicCases() {
        XCTAssertTrue(UpdateChecker.isNewer("0.6.0", than: "0.5.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.5.0", than: "0.5.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.4.9", than: "0.5.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.5.1", than: "0.5"))
    }

    func testCheckForUpdateReturnsInfoWhenNewer() async {
        MockURLProtocol.handler = { [weak self] _ in (200, self!.releasePayload(tag: "v0.6.0")) }
        let info = await UpdateChecker.checkForUpdate(currentVersion: "0.5.0", session: .mocked())
        XCTAssertEqual(info?.version, "0.6.0")
        XCTAssertEqual(info?.zipURL, URL(string: "https://example.com/coruja.zip"))
    }

    func testCheckForUpdateReturnsNilWhenNotNewer() async {
        MockURLProtocol.handler = { [weak self] _ in (200, self!.releasePayload(tag: "v0.5.0")) }
        let info = await UpdateChecker.checkForUpdate(currentVersion: "0.5.0", session: .mocked())
        XCTAssertNil(info)
    }

    func testCheckForUpdateReturnsNilOnHTTPError() async {
        MockURLProtocol.handler = { _ in (500, Data()) }
        let info = await UpdateChecker.checkForUpdate(currentVersion: "0.5.0", session: .mocked())
        XCTAssertNil(info)
    }

    func testDismissalGate() {
        let defaults = UserDefaults(suiteName: "coruja-update-checker-tests")!
        defaults.removePersistentDomain(forName: "coruja-update-checker-tests")

        XCTAssertFalse(UpdateChecker.isDismissed("0.6.0", defaults: defaults))
        UpdateChecker.dismiss("0.6.0", defaults: defaults)
        XCTAssertTrue(UpdateChecker.isDismissed("0.6.0", defaults: defaults))
        XCTAssertFalse(UpdateChecker.isDismissed("0.7.0", defaults: defaults))

        defaults.removePersistentDomain(forName: "coruja-update-checker-tests")
    }
}
```

- [ ] **Step 3: Run the tests**

Run: `swift test --filter UpdateCheckerTests`
Expected: 6 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/coruja/UpdateChecker.swift Tests/corujaTests/UpdateCheckerTests.swift
git commit -m "Add UpdateChecker: GitHub release lookup, semver compare, dismissal gate"
```

---

## Task 9: UpdateInstaller — download, unzip, de-quarantine, replace, relaunch

**Files:**
- Create: `Sources/coruja/UpdateInstaller.swift`

**Interfaces:**
- Consumes: `UpdateInfo` (Task 8)
- Produces: `UpdateInstaller.install(_:) async throws`, `UpdateInstaller.InstallError`

- [ ] **Step 1: Write `UpdateInstaller.swift`**

```swift
import AppKit
import Foundation

/// Downloads a new release's zip, unpacks it, and replaces the running
/// /Applications/Coruja.app, then relaunches the new copy and terminates
/// this process. Every step before "replace" must succeed — the currently
/// running app is only ever touched (moved to the Trash, not deleted) after
/// the new bundle is downloaded, unzipped, and validated.
enum UpdateInstaller {
    enum InstallError: Error, CustomStringConvertible {
        case downloadFailed
        case unzipFailed
        case invalidBundle
        case installFailed(String)

        var description: String {
            switch self {
            case .downloadFailed: return "não foi possível baixar a atualização"
            case .unzipFailed: return "não foi possível descompactar a atualização"
            case .invalidBundle: return "o pacote baixado não parece um app válido"
            case .installFailed(let reason): return "não foi possível instalar a atualização (\(reason))"
            }
        }
    }

    @MainActor
    static func install(_ info: UpdateInfo, session: URLSession = .shared) async throws {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("coruja", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let zipPath = cacheDir.appendingPathComponent("update.zip")
        try? FileManager.default.removeItem(at: zipPath)

        guard
            let (downloaded, response) = try? await session.download(from: info.zipURL),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw InstallError.downloadFailed }
        try FileManager.default.moveItem(at: downloaded, to: zipPath)

        let extractDir = cacheDir.appendingPathComponent("extracted", isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractDir.path], error: .unzipFailed)

        guard
            let contents = try? FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil),
            let appDir = contents.first(where: { $0.pathExtension == "app" }),
            FileManager.default.fileExists(atPath: appDir.appendingPathComponent("Contents/Info.plist").path)
        else { throw InstallError.invalidBundle }

        // Removes the quarantine flag Gatekeeper would otherwise attach to
        // anything downloaded — this is the manual `xattr -cr` step the
        // README asks users to run today, done for them.
        try run("/usr/bin/xattr", ["-cr", appDir.path], error: .installFailed("xattr"))

        let installedURL = URL(fileURLWithPath: "/Applications/Coruja.app")
        if FileManager.default.fileExists(atPath: installedURL.path) {
            try FileManager.default.trashItem(at: installedURL, resultingItemURL: nil)
        }
        try FileManager.default.moveItem(at: appDir, to: installedURL)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: installedURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private static func run(_ launchPath: String, _ args: [String], error: InstallError) throws {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = args
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw error }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds cleanly. Not unit-tested (per the spec — this is a
system-integration path that moves/replaces a real app bundle; automated
tests here would need to fake `/Applications`, which isn't worth the
complexity for a personal-use app). Verified manually in Task 11 alongside
the Settings "check for updates" button, against a real throwaway GitHub
release.

- [ ] **Step 3: Commit**

```bash
git add Sources/coruja/UpdateInstaller.swift
git commit -m "Add UpdateInstaller: download, unzip, de-quarantine, replace, relaunch"
```

---

## Task 10: Automatic update check + popup, wired into AppController

**Files:**
- Modify: `Sources/coruja/Coruja.swift`

**Interfaces:**
- Consumes: `UpdateChecker.checkForUpdate/isDismissed/dismiss` (Task 8),
  `UpdateInstaller.install(_:)` (Task 9), `NotificationPanel` (Task 7)

- [ ] **Step 1: Add state and scheduling to `AppController`**

Add alongside the other stored properties (near `meetingPrompt`):

```swift
    private let updatePrompt = NotificationPanel()
    private var updateCheckTimer: Timer?
    private static let updateCheckInterval: TimeInterval = 86400
```

In `init(root:)`, after `setupMeetingDetector()`, add:

```swift
        scheduleUpdateChecks()
```

- [ ] **Step 2: Add the scheduling + prompt methods**

Add near `setupMeetingDetector`:

```swift
    /// Checks GitHub Releases once at launch and every 24h thereafter (see
    /// UpdateChecker). The automatic path never re-prompts for a version the
    /// user already dismissed — the manual "Verificar atualizações" button
    /// in Settings bypasses that and always checks live.
    private func scheduleUpdateChecks() {
        Task { await checkForUpdateAutomatically() }
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.updateCheckInterval, repeats: true) { [weak self] _ in
            Task { await self?.checkForUpdateAutomatically() }
        }
    }

    private func checkForUpdateAutomatically() async {
        guard let info = await UpdateChecker.checkForUpdate() else { return }
        guard !UpdateChecker.isDismissed(info.version) else { return }
        presentUpdatePrompt(info, onIgnore: { UpdateChecker.dismiss(info.version) })
    }

    /// Shared by the automatic path and Settings' manual "Verificar
    /// atualizações" button (see SettingsRootView) — not private, called
    /// across the module.
    func presentUpdatePrompt(_ info: UpdateInfo, onIgnore: @escaping () -> Void) {
        updatePrompt.show(
            icon: "arrow.down.circle",
            title: "Nova versão \(info.version) disponível",
            message: "Atualizar agora?",
            actionTitle: "Atualizar",
            ignoreTitle: "Depois",
            position: .bottomRightOfScreen,
            autoDismiss: nil,
            onAction: { [weak self] in self?.performUpdate(info) },
            onIgnore: onIgnore
        )
    }

    private func performUpdate(_ info: UpdateInfo) {
        Task {
            do {
                try await UpdateInstaller.install(info)
            } catch {
                notifyUser(title: "Falha ao atualizar", body: "\(error)")
            }
        }
    }
```

- [ ] **Step 3: Stop the timer on termination**

In `prepareForTermination()`, add:

```swift
        updateCheckTimer?.invalidate()
```

right after `meetingPollTimer?.invalidate()`.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 5: Manual verification**

Point `UpdateChecker`'s `releasesURL` at a throwaway test repo (or
temporarily lower `updateCheckInterval` and bump `CFBundleShortVersionString`
down in a local `Packaging/Info.plist` copy) to confirm: the bottom-right
popup appears on launch with the new vibrancy style, clicking "Depois"
dismisses it and it does not reappear on a second launch, and clicking
"Atualizar" against a real small test zip successfully replaces and
relaunches the app. Revert any temporary version/URL changes before
committing.

- [ ] **Step 6: Commit**

```bash
git add Sources/coruja/Coruja.swift
git commit -m "Check for updates on launch + every 24h; show update popup"
```

---

## Task 11: Settings — "Sobre" section with manual update check

**Files:**
- Modify: `Sources/coruja/UI/SettingsRootView.swift`

**Interfaces:**
- Consumes: `UpdateChecker.checkForUpdate(currentVersion:)` (Task 8),
  `UpdateInstaller.install(_:)` (Task 9)

- [ ] **Step 1: Add state for the About section**

Add alongside the other `@State` properties:

```swift
    @State private var updateCheckState: UpdateCheckState = .idle

    private enum UpdateCheckState {
        case idle, checking, upToDate, available(UpdateInfo), installing, failed(String)
    }
```

- [ ] **Step 2: Add the section to the view body**

Add as the last section inside the outer `VStack` in `body`, after the
"Resumo e título automático" section:

```swift
                section("Sobre") {
                    labeledRow("Versão") {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.rowTitleColor)
                    }
                    updateCheckRow
                }
```

Add the row's view below the other `// MARK: -` view helpers:

```swift
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
```

- [ ] **Step 3: Build and manually verify**

Run: `swift build`
Expected: builds cleanly.

Launch the app, open Settings, scroll to "Sobre", confirm the current
version is shown, click "Verificar atualizações" and confirm it reports
"você já está na versão mais recente" (since the real repo has no newer
release at plan-writing time) or shows an available update + "Atualizar"
button if one exists by the time this is implemented.

- [ ] **Step 4: Commit**

```bash
git add Sources/coruja/UI/SettingsRootView.swift
git commit -m "Settings: add Sobre section with manual update check"
```

---

## Final check

- [ ] Run the full test suite: `swift test`
  Expected: all tests across `ConfigTests`, `SummaryEngineTests`,
  `TitleEngineTests`, `UpdateCheckerTests` pass.
- [ ] Run a full release build once: `swift build -c release`
  Expected: builds cleanly (catches anything the debug build's incremental
  compilation might have papered over).
- [ ] `grep -rn "Ollama\|ollama" Sources/` — expected to return nothing
  except historical wording that's actually still accurate (there should be
  none; if anything shows up, it's a leftover reference to fix).
