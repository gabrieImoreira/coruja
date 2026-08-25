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
/// 2. One small Ollama call turns the resulting keywords into a short
///    phrase — the keywords alone read as a tag list, not a title.
///
/// Piggybacks on the same opt-in `llm_pass` config as SummaryEngine (see
/// Config.swift): tested the keyword step without an LLM afterward and it
/// wasn't good enough to ship as the default, so there's no LLM-free path
/// here. Without Ollama, a session simply keeps showing its timestamp.
///
/// Titles are stored per-session in `.title` (plain text, one line) — never
/// the folder name itself (RecordingSession keeps that timestamp-only on
/// purpose) — and are user-editable from the notes window; an edit just
/// overwrites this file.
enum TitleEngine {
    static let titleFileName = ".title"

    enum TitleError: Error, CustomStringConvertible {
        case noKeywords
        case httpError(Int)
        case empty

        var description: String {
            switch self {
            case .noKeywords: return "not enough text to extract keywords from"
            case .httpError(let code): return "Ollama returned HTTP \(code) — is it running? (ollama serve)"
            case .empty: return "model returned an empty title"
            }
        }
    }

    /// - Parameters:
    ///   - segments: this session's transcript segments (speaker, text).
    ///   - root: recordings root, scanned for sibling sessions' `.transcript.json`
    ///     to build the TF-IDF corpus.
    ///   - own: this session's directory — excluded when scanning `root`.
    static func generate(
        segments: [(speaker: String, text: String)],
        root: URL,
        excluding own: URL,
        model: String,
        endpoint: URL
    ) async throws -> String {
        let ownWords = wordCounts(segments.map(\.text))
        guard !ownWords.isEmpty else { throw TitleError.noKeywords }

        let corpus = corpusWordCounts(root: root, excluding: own)
        let topKeywords = keywords(own: ownWords, corpus: corpus)
        guard !topKeywords.isEmpty else { throw TitleError.noKeywords }

        let sample = segments.prefix(8)
            .map { "\($0.speaker == "me" ? "Eu" : $0.speaker): \($0.text)" }
            .joined(separator: "\n")
        let title = try await askOllama(keywords: topKeywords, sample: sample, model: model, endpoint: endpoint)
        guard !title.isEmpty else { throw TitleError.empty }
        return title
    }

    // MARK: - TF-IDF

    /// Kept short and conversational-filler-focused on purpose — this only
    /// needs to strip words common enough to show up as "top words" in
    /// nearly any transcript, not be a complete Portuguese stopword list.
    /// TF-IDF against the corpus already discounts words that are frequent
    /// but not distinctive; this list is a cheap first pass before that.
    private static let stopwords: Set<String> = Set("""
    de do da dos das em no na nos nas por para com sem sob sobre e ou mas
    que se não nao sim já ja aí ai né ne tá ta to é eh vai vou vamos foi
    era são sao eu tu ele ela nós nos eles elas você voce vocês voces seu
    sua seus suas meu minha meus minhas isso isto aquilo esse essa esses
    essas este esta estes estas aqui ali muito muita muitos muitas mais
    menos bem mal só so coisa coisas tipo assim então entao pra pro pois
    porque como quando onde qual quais tudo nada nenhum nenhuma cada gente
    ok certo beleza obrigado obrigada oi olá ola alô alo bom boa dia tarde
    noite tbm também tambem depois antes agora hoje ontem tem ver acho
    está esta tava pode podia ser vai foi tão tao lá la um uma uns umas
    os as o a
    """.split(separator: "\n").joined(separator: " ").split(separator: " ").map(String.init))

    private static func wordCounts(_ texts: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for text in texts {
            for word in text.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            where word.count > 2 && !stopwords.contains(word) {
                counts[word, default: 0] += 1
            }
        }
        return counts
    }

    /// Only what TF-IDF needs from another session: its transcript text,
    /// read from the same `.transcript.json` the coordinator already writes.
    private struct MiniTranscript: Decodable {
        struct Segment: Decodable { let text: String }
        let segments: [Segment]
    }

    /// Capped at the most recent 50 sessions — a growing corpus keeps
    /// improving title quality, but this shouldn't re-read an unbounded
    /// history on every transcription.
    private static func corpusWordCounts(root: URL, excluding own: URL, limit: Int = 50) -> [[String: Int]] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        let others = entries
            .filter { $0.hasDirectoryPath && $0 != own }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
        return others.compactMap { dir in
            let url = dir.appendingPathComponent(TranscriptionCoordinator.transcriptJSONFileName)
            guard
                let data = try? Data(contentsOf: url),
                let decoded = try? JSONDecoder().decode(MiniTranscript.self, from: data)
            else { return nil }
            let counts = wordCounts(decoded.segments.map(\.text))
            return counts.isEmpty ? nil : counts
        }
    }

    private static func keywords(own: [String: Int], corpus: [[String: Int]], topN: Int = 6) -> [String] {
        let allDocs = corpus + [own]
        let n = Double(allDocs.count)
        var documentFrequency: [String: Int] = [:]
        for doc in allDocs {
            for word in Set(doc.keys) { documentFrequency[word, default: 0] += 1 }
        }

        let ownTotal = Double(own.values.reduce(0, +))
        let scored = own.map { word, count -> (String, Double) in
            let tf = Double(count) / ownTotal
            let idf = log(n / (1 + Double(documentFrequency[word] ?? 0)))
            return (word, tf * idf)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(topN).map(\.0)
    }

    // MARK: - Ollama

    private static func askOllama(keywords: [String], sample: String, model: String, endpoint: URL) async throws -> String {
        let prompt = """
        Palavras-chave extraídas de uma reunião (ordem de relevância): \(keywords.joined(separator: ", "))

        Trecho do início da reunião (contexto, pode ignorar saudações):
        \(sample)

        Gere um título curto (3 a 6 palavras, em português) que descreva o \
        assunto principal desta reunião, baseado nas palavras-chave acima. \
        Responda APENAS o título, sem aspas, sem explicação.
        """
        var request = URLRequest(url: endpoint.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false,
            "messages": [["role": "user", "content": prompt]],
            "options": ["temperature": 0.3, "num_ctx": 2048],
        ])
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TitleError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        struct OllamaResponse: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let ollama = try JSONDecoder().decode(OllamaResponse.self, from: data)
        var title = ollama.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        // The model sometimes wraps the title in quotes or adds a trailing
        // line despite the "only the title" instruction — strip both.
        if let firstLine = title.split(separator: "\n", maxSplits: 1).first { title = String(firstLine) }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
        return title
    }
}
