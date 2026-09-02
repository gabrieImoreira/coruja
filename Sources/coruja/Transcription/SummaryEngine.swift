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
