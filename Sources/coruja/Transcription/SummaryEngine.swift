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

    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// - Parameters:
    ///   - segments: transcript segments in chronological order.
    ///   - apiKey: OpenAI API key (see Config.openaiApiKey) — throws
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
        switch summaryType {
        case .ata:
            // Always compose, even for a single chunk — the per-chunk pass
            // only extracts grounded raw notes (see summarizeChunk's ata
            // shape); composeAta is what actually writes the structured
            // document (numbered sections, tables, the closing checklists).
            finalSummary = try await composeAta(
                from: partialSummaries, actionItems: actionItems, apiKey: apiKey, model: model, session: session
            )
        case .topicos:
            if partialSummaries.count <= 1 {
                finalSummary = partialSummaries.first ?? ""
            } else {
                finalSummary = try await reduceSummaries(partialSummaries, apiKey: apiKey, model: model, session: session)
            }
        }

        return Summary(resumo: finalSummary, itensDeAcao: actionItems)
    }

    /// Renders a `Summary` as the Markdown written to `summary.md` (or
    /// `summary-test.md` for the `Summarize` CLI command).
    ///
    /// `.ata`'s `resumo` is already the complete, composed document (own H1
    /// title, numbered sections, closing checklists — see `composeAta`),
    /// including its own "Questões em aberto" table built from the action
    /// items — so it's written as-is, with no extra heading or duplicate
    /// action-items section tacked on.
    ///
    /// `.topicos`'s `resumo` is just the topic-by-topic body (its own `##`/
    /// `###` sub-headings, no document title) — this prepends the "# Resumo"
    /// heading and appends a plain action-items list, same as before.
    static func render(_ summary: Summary, type: SummaryType) -> String {
        switch type {
        case .ata:
            return summary.resumo
        case .topicos:
            var lines = ["# Resumo", "", summary.resumo, ""]
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
              "resumo": "## Tópicos\\n\\n### <nome do tópico 1>\\n<4 a 7 frases detalhando o que foi dito: o que foi discutido, argumentos levantados, alternativas mencionadas, e a conclusão ou próximo passo se houve um>\\n\\n### <nome do tópico 2>\\n...",
              "itens_de_acao": [
                {"item": "descrição da ação", "responsavel": "nome citado ou null", "prazo": "prazo citado ou null"}
              ]
            }
            Liste só os tópicos realmente discutidos NESTE trecho — pode ser um só. \
            Prefira profundidade a brevidade: é melhor detalhar bem 2 tópicos do que \
            listar 5 tópicos superficiais.
            """
        case .ata:
            // This chunk-level pass only extracts grounded raw notes, tagged
            // by category — composeAta (the reduce step, always run for
            // .ata) is what turns these into the actual structured document.
            // Keeping this pass's job narrow (extraction, not writing) is
            // what lets the reduce step synthesize across chunks instead of
            // just concatenating already-finished prose.
            shapeInstructions = """
            Responda em JSON com exatamente este formato:
            {
              "resumo": "**Tópicos abordados:**\\n- <assunto discutido neste trecho>\\n\\n**Decisões:**\\n- <decisão tomada, com o racional se foi dito>\\n\\n**Pendências:**\\n- <algo que ficou em aberto ou precisa de confirmação — inclua responsável entre parênteses se foi citado>\\n\\n**Pontos de atenção:**\\n- <algo que muda um comportamento existente, um risco, ou um problema apontado>",
              "itens_de_acao": [
                {"item": "descrição da ação", "responsavel": "nome citado ou null", "prazo": "prazo citado ou null"}
              ]
            }
            Omita inteiramente qualquer uma das quatro seções (com o cabeçalho em \
            negrito e tudo) se não houver nada real desse tipo neste trecho — não \
            invente conteúdo só para preencher a seção. Seja específico: cite os \
            termos exatos usados (nomes de sistemas, canais, campos, siglas), não \
            generalize.
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

    /// Turns the per-chunk raw notes (see `summarizeChunk`'s `.ata` shape)
    /// plus the flattened action items into the actual ata: a proper
    /// briefing document with its own title, numbered thematic sections
    /// (topics from different chunks about the same subject are merged into
    /// one section, not repeated), inline status tags, tables where the
    /// content is naturally tabular, and two closing sections every ata
    /// needs — a checklist of what was actually decided, and a table of
    /// what's still open with who owns it.
    ///
    /// Always called for `.ata`, even for a single chunk (a short meeting
    /// still deserves the proper structure, not just the raw extraction
    /// pass's bullet notes) — this is the pass that actually *writes* the
    /// document; `summarizeChunk` only ever extracts grounded raw material.
    private static func composeAta(
        from partials: [String],
        actionItems: [ActionItem],
        apiKey: String,
        model: String,
        session: URLSession
    ) async throws -> String {
        let notes = partials.enumerated()
            .map { "### Notas do trecho \($0 + 1)\n\($1)" }
            .joined(separator: "\n\n")

        let actionItemsJSON: String
        if actionItems.isEmpty {
            actionItemsJSON = "(nenhum item de ação foi identificado nos trechos)"
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            actionItemsJSON = (try? encoder.encode(actionItems)).flatMap { String(data: $0, encoding: .utf8) }
                ?? "(nenhum item de ação foi identificado nos trechos)"
        }

        let prompt = """
        Você é responsável por escrever a ATA de uma reunião de trabalho, em português, \
        a partir de notas já extraídas trecho a trecho da transcrição (abaixo). As notas \
        já são fiéis ao que foi dito — seu trabalho agora é ORGANIZAR e ESTRUTURAR, não \
        resumir de novo nem simplificar. O resultado deve ter nível de um documento \
        corporativo de verdade, não um resumo genérico.

        REGRAS OBRIGATÓRIAS:
        - NÃO invente nada que não esteja nas notas abaixo ou na lista de itens de ação. \
        Toda informação tem que rastrear para algo que as notas realmente dizem.
        - NÃO generalize os termos específicos citados (nomes de sistemas, siglas, \
        canais, campos) — use exatamente os termos das notas.
        - Assuntos relacionados discutidos em trechos diferentes (ex.: o mesmo tópico \
        retomado depois na reunião) devem virar UMA seção só, não uma seção repetida \
        por trecho — organize por ASSUNTO, não pela ordem cronológica dos trechos.
        - Toda pendência, decisão pendente ou item de ação deve aparecer na tabela final \
        "Questões em aberto" — não deixe nada órfão só na seção temática.

        ESTRUTURA OBRIGATÓRIA DO DOCUMENTO (em Markdown):

        1. Um título nível 1 (`# `) resumindo o assunto principal da reunião em uma linha.
        2. Um bloco de citação (`> `) logo abaixo do título, com 1-2 frases de contexto \
        sobre do que se trata a reunião (baseado no que as notas mostram) e a legenda \
        dos marcadores usados: `[MUDANÇA]` (altera algo que já existia), `[DECISÃO]` \
        (algo foi decidido), `[PENDENTE]` (precisa de definição/confirmação, indique \
        de quem se souber — ex. `[PENDENTE — NOME]`), `[ATENÇÃO]` (risco, problema ou \
        ponto que merece destaque).
        3. Seções numeradas `## PARTE N — TÍTULO DA SEÇÃO`, cada uma cobrindo um \
        assunto coeso da reunião (não um trecho/chunk — um ASSUNTO). Dentro de cada \
        seção, use bullets (`- `) para os pontos, aplique os marcadores acima onde \
        fizer sentido, e use uma tabela Markdown (`| coluna | coluna |`) sempre que o \
        conteúdo for naturalmente comparativo ou tabular (ex.: uma lista de itens com \
        um atributo cada, como "serviço → decisão", "opção → status").
        4. Uma seção final `## Definições desta reunião` — uma lista de bullets, cada \
        um começando com "✔ ", resumindo objetivamente cada decisão que de fato foi \
        tomada (não pendências, só o que ficou definido).
        5. Uma seção final `## Questões em aberto` — uma tabela Markdown com colunas \
        `| # | Item | Responsável | Prazo |`, listando TODOS os itens de ação (da lista \
        JSON abaixo) e qualquer outra pendência real das notas que ainda não tem \
        solução. Use "—" quando responsável ou prazo não foram citados. Numere as \
        linhas a partir de 1.

        Responda em JSON com exatamente este formato:
        {"resumo": "o documento completo, em Markdown, seguindo a estrutura acima"}

        ITENS DE AÇÃO IDENTIFICADOS (JSON, para você incorporar na tabela final):
        \(actionItemsJSON)

        NOTAS EXTRAÍDAS DOS TRECHOS DA REUNIÃO, EM ORDEM CRONOLÓGICA:
        \(notes)
        """

        struct Composed: Codable { let resumo: String }
        let data = try await callOpenAIRaw(prompt: prompt, apiKey: apiKey, model: model, session: session)
        guard let composed = try? JSONDecoder().decode(Composed.self, from: data) else {
            // Composing failing shouldn't lose the extraction pass's work —
            // fall back to the raw per-chunk notes joined as-is.
            return notes
        }
        return composed.resumo
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
