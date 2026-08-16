import Foundation

/// Optional local-LLM pass over a finished transcript: executive summary +
/// action items, via Ollama's HTTP API. Opt-in (`transcription.llm_pass` in
/// config) and always local — no cloud model, matching the rest of this
/// app's "nothing leaves the machine" design. See Config.swift.
///
/// This generates text, unlike the rest of the pipeline which only
/// transcribes what was actually said — so the prompt's non-negotiable rule
/// is not inventing content, not improving grammar, and not including an
/// action item unless it's explicitly there in the transcript. A summary
/// that reads better than the meeting but says something nobody said is
/// worse than no summary.
///
/// Map-reduce over ~10min chunks, not one call over the whole transcript.
/// Confirmed live against a real 87min/~11k-word meeting with an 8B model:
/// a single-pass summary was technically valid (correct JSON schema) but
/// read as generic corporate boilerplate — no domain terms from an hour of
/// substantive insurance-workflow discussion made it into the summary at
/// all. An 8B model loses the thread over that much transcript even with a
/// large enough context window to physically fit it. Each ~10min chunk is
/// short enough that the same model stays grounded in it.
enum SummaryEngine {
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
        case httpError(Int)
        case unparseable(String)

        var description: String {
            switch self {
            case .emptyTranscript: return "nothing to summarize"
            case .httpError(let code): return "Ollama returned HTTP \(code) — is it running? (ollama serve)"
            case .unparseable(let raw): return "model didn't return valid JSON: \(raw.prefix(200))"
            }
        }
    }

    /// - Parameters:
    ///   - segments: transcript segments in chronological order.
    ///   - chunkMinutes: size of each map step. 10min keeps a real meeting's
    ///     worth of context small enough for an 8B model to stay grounded in,
    ///     without so many chunks that the reduce step loses coherence.
    static func summarize(
        segments: [TimedSegment],
        model: String,
        endpoint: URL,
        chunkMinutes: Double = 10
    ) async throws -> Summary {
        guard !segments.isEmpty else { throw SummaryError.emptyTranscript }

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

        // Map: each chunk summarized independently, same grounded-extraction
        // prompt as a short transcript would get.
        var partialSummaries: [String] = []
        var actionItems: [ActionItem] = []
        for chunk in chunks {
            let text = chunk.map { "\($0.speaker == "me" ? "Eu" : $0.speaker): \($0.text)" }.joined(separator: "\n")
            let partial = try await summarizeChunk(transcriptText: text, model: model, endpoint: endpoint)
            if !partial.resumo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                partialSummaries.append(partial.resumo)
            }
            actionItems += partial.itensDeAcao
        }

        // Reduce: a single chunk needs no reduction. Multiple chunks get
        // combined from the already-extracted bullet summaries (short input,
        // stays grounded) rather than re-reading the full transcript.
        let finalSummary: String
        if partialSummaries.count <= 1 {
            finalSummary = partialSummaries.first ?? ""
        } else {
            finalSummary = try await reduceSummaries(partialSummaries, model: model, endpoint: endpoint)
        }

        return Summary(resumo: finalSummary, itensDeAcao: actionItems)
    }

    private static func summarizeChunk(
        transcriptText: String,
        model: String,
        endpoint: URL
    ) async throws -> Summary {
        let prompt = """
        Você recebe abaixo a transcrição de um trecho de uma reunião de trabalho, em português.

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
        "resumo", não ação de ninguém. Na dúvida, não inclua. Sem compromisso \
        claro, devolva uma lista vazia — a lista vazia é o resultado esperado \
        na maioria dos trechos, não uma falha.

        Responda em JSON com exatamente este formato:
        {
          "resumo": "1 a 3 frases resumindo o que foi discutido NESTE trecho",
          "itens_de_acao": [
            {"item": "descrição da ação", "responsavel": "nome citado ou null", "prazo": "prazo citado ou null"}
          ]
        }

        TRECHO DA TRANSCRIÇÃO:
        \(transcriptText)
        """
        return try await callOllama(prompt: prompt, model: model, endpoint: endpoint)
    }

    private static func reduceSummaries(
        _ partials: [String],
        model: String,
        endpoint: URL
    ) async throws -> String {
        let bulletList = partials.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
        let prompt = """
        Abaixo estão resumos de trechos sucessivos de UMA MESMA reunião, em ordem \
        cronológica. Combine-os num resumo executivo único e coeso.

        REGRAS OBRIGATÓRIAS:
        - NÃO invente nada que não esteja nos resumos abaixo.
        - NÃO remova termos técnicos específicos (nomes de sistemas, processos, campos).
        - Elimine só repetição literal entre trechos adjacentes; mantenha os assuntos distintos.

        Responda em JSON com exatamente este formato:
        {"resumo": "6 a 10 frases combinando os pontos abaixo, na ordem em que aparecem"}

        RESUMOS POR TRECHO:
        \(bulletList)
        """
        struct Reduced: Codable { let resumo: String }
        let data = try await callOllamaRaw(prompt: prompt, model: model, endpoint: endpoint)
        guard let reduced = try? JSONDecoder().decode(Reduced.self, from: data) else {
            // Reduce failing shouldn't lose the map step's work — fall back to
            // the partial summaries joined as-is.
            return partials.joined(separator: " ")
        }
        return reduced.resumo
    }

    private static func callOllama(prompt: String, model: String, endpoint: URL) async throws -> Summary {
        let data = try await callOllamaRaw(prompt: prompt, model: model, endpoint: endpoint)
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else {
            throw SummaryError.unparseable(String(data: data, encoding: .utf8) ?? "")
        }
        return summary
    }

    /// Raw call to Ollama's chat API, returning the model's JSON content as
    /// `Data` for the caller to decode into whatever shape it asked for.
    private static func callOllamaRaw(prompt: String, model: String, endpoint: URL) async throws -> Data {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false,
            "format": "json",
            "messages": [["role": "user", "content": prompt]],
            // A ~10min chunk plus instructions comfortably fits well under
            // Ollama's default context window, but the reduce step's combined
            // bullet list can still run long on an hours-long meeting —
            // keeping this generous costs little since chunks are short.
            "options": ["num_ctx": 8192],
        ])
        request.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SummaryError.httpError(code)
        }

        struct OllamaResponse: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let ollama = try JSONDecoder().decode(OllamaResponse.self, from: data)
        guard let contentData = ollama.message.content.data(using: .utf8) else {
            throw SummaryError.unparseable(ollama.message.content)
        }
        return contentData
    }
}
