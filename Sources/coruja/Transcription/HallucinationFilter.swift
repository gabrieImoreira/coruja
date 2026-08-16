import Foundation

/// Post-decode rejection of hallucinated segments.
///
/// This exists because of a counterintuitive fact about WhisperKit's fallback
/// loop: **text that fails every threshold is kept, not discarded.**
/// TranscribeTask.swift:289-384 runs the temperature ladder and, when it is
/// exhausted, returns the result of the *last* attempt regardless of whether it
/// still violates `compressionRatioThreshold` / `logProbThreshold`. There is no
/// best-of selection and no discard path.
///
/// So `compressionRatioThreshold` and `logProbThreshold` do not filter anything
/// — they only decide whether to retry hotter. Filtering has to happen here.
///
/// Two signals are unusable and it matters:
///   - `noSpeechProb` is always 0.0 (TextDecoder.swift:993 hardcodes it).
///   - `compressionRatio` is computed over Int32-serialized token ids
///     (TextUtilities.swift:14-28), not UTF-8 text, so it is not on the same
///     scale as OpenAI's 2.4. We recompute it over the text below, where 2.4 is
///     the number the Whisper literature actually refers to.
///
/// Note `avgLogprob` / `compressionRatio` / `temperature` are per-*window*
/// values copied identically onto every segment split from that window.
struct HallucinationFilter {
    /// A segment as it comes out of the decoder, plus the window-level
    /// confidence signals we need to judge it.
    struct Candidate {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let avgLogprob: Float
        let temperature: Float
        /// Identifies the decoder window, so rule 5 can reject in bulk.
        let windowIndex: Int

        var duration: TimeInterval { max(0, end - start) }
    }

    struct Report {
        var repetitionCollapsed = 0
        var droppedCompression = 0
        var droppedDuplicate = 0
        var droppedFiller = 0
        var droppedWindows = 0

        var isEmpty: Bool {
            repetitionCollapsed == 0 && droppedCompression == 0
                && droppedDuplicate == 0 && droppedFiller == 0 && droppedWindows == 0
        }

        var description: String {
            "filter: \(repetitionCollapsed) repetition collapsed, "
                + "\(droppedCompression) compression, \(droppedDuplicate) duplicate, "
                + "\(droppedFiller) filler, \(droppedWindows) whole windows"
        }
    }

    /// Whole-segment texts observed as hallucinations on silence in real pt-BR
    /// recordings. These are also real speech in a meeting, which is why no rule
    /// drops on this list alone — every use is conjunctive.
    static let fillers: Set<String> = [
        "e aí", "e ai", "aí", "obrigado", "obrigada", "aplausos", "amém", "amem",
        "música", "musica", "tchau", "tchau tchau", "valeu", "até mais", "ate mais",
        "obrigado por assistir", "obrigada por assistir", "inscreva-se no canal",
        "legendas pela comunidade amara.org", "legendado por", "legendas por",
        "estou aqui para te ajudar", "muito obrigado", "beleza",
    ]

    var compressionRatioLimit: Float = 2.4
    var lowConfidence: Float = -1.0
    var duplicateMaxDuration: TimeInterval = 3.0
    var fillerMaxDuration: TimeInterval = 1.2
    /// Fraction of a window's segments that must be rejected before the whole
    /// window goes. Hallucination arrives in blocks.
    var windowRejectionRatio: Double = 0.6

    func apply(to candidates: [Candidate]) -> (kept: [Candidate], report: Report) {
        var report = Report()
        guard !candidates.isEmpty else { return ([], report) }

        // Rule 1 — collapse consecutive repetition inside a segment.
        var staged: [Candidate] = []
        for c in candidates {
            let collapsed = Self.collapsingRepetition(c.text)
            if collapsed != c.text { report.repetitionCollapsed += 1 }
            let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            staged.append(Candidate(
                start: c.start, end: c.end, text: trimmed,
                avgLogprob: c.avgLogprob, temperature: c.temperature,
                windowIndex: c.windowIndex
            ))
        }

        // Rules 2–4.
        var kept: [Candidate] = []
        var rejectedPerWindow: [Int: Int] = [:]
        var totalPerWindow: [Int: Int] = [:]

        for c in staged {
            totalPerWindow[c.windowIndex, default: 0] += 1
            let norm = Self.normalize(c.text)

            // Rule 2 — text-level compression ratio (comparable to 2.4).
            if Self.textCompressionRatio(c.text) > compressionRatioLimit {
                report.droppedCompression += 1
                rejectedPerWindow[c.windowIndex, default: 0] += 1
                continue
            }

            let previousNorm = kept.last.map { Self.normalize($0.text) }
            let isDuplicate = previousNorm == norm
            let previousShort = kept.last.map { $0.duration < duplicateMaxDuration } ?? false

            // Rule 3 — duplicate of neighbour, both short. This is what kills
            // the column of "E aí" every ~2 s in the observed transcript.
            if isDuplicate, c.duration < duplicateMaxDuration, previousShort {
                report.droppedDuplicate += 1
                rejectedPerWindow[c.windowIndex, default: 0] += 1
                continue
            }

            // Rule 4 — known filler AND (low confidence OR very short OR
            // duplicate). Never on the filler list alone: "Obrigado" and
            // "Beleza" are real turns in these meetings.
            if Self.fillers.contains(norm) {
                let suspicious = c.avgLogprob < lowConfidence
                    || c.duration < fillerMaxDuration
                    || isDuplicate
                if suspicious {
                    report.droppedFiller += 1
                    rejectedPerWindow[c.windowIndex, default: 0] += 1
                    continue
                }
            }

            kept.append(c)
        }

        // Rule 5 — drop windows that were mostly rejected.
        let poisonedWindows = totalPerWindow.compactMap { (window, total) -> Int? in
            guard total > 0 else { return nil }
            let rejected = rejectedPerWindow[window] ?? 0
            return Double(rejected) / Double(total) >= windowRejectionRatio ? window : nil
        }
        if !poisonedWindows.isEmpty {
            let poisoned = Set(poisonedWindows)
            let before = kept.count
            kept = kept.filter { !poisoned.contains($0.windowIndex) }
            report.droppedWindows = before - kept.count
        }

        return (kept, report)
    }

    // MARK: - Metrics

    /// zlib over UTF-8 text — the OpenAI-comparable form, unlike WhisperKit's
    /// token-id version. Values above ~2.4 mean the text is highly repetitive.
    static func textCompressionRatio(_ text: String) -> Float {
        let data = Data(text.utf8)
        guard data.count > 32 else { return 1 }
        guard let compressed = try? (data as NSData).compressed(using: .zlib) else { return 1 }
        guard compressed.length > 0 else { return .infinity }
        return Float(data.count) / Float(compressed.length)
    }

    /// Collapse a unigram or bigram repeated 3+ times consecutively down to one
    /// occurrence. Catches "E aí E aí E aí" inside a single segment, and the
    /// "não não não não" / "1.302 1.302" runs the decoder produces on unclear
    /// audio.
    static func collapsingRepetition(_ text: String, minRuns: Int = 3) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= minRuns else { return text }

        // Unigram runs. Advance by 1 when the run is short, so genuine doubles
        // ("muito muito obrigado") survive untouched.
        var pass1: [String] = []
        var i = 0
        while i < words.count {
            var run = 1
            while i + run < words.count,
                  normalize(words[i + run]) == normalize(words[i]) { run += 1 }
            pass1.append(words[i])
            i += run >= minRuns ? run : 1
        }

        // Bigram runs, same advance-by-1 rule so a run starting at an odd
        // offset is still detected.
        var pass2: [String] = []
        var j = 0
        while j < pass1.count {
            if j + 1 < pass1.count {
                let a = normalize(pass1[j]), b = normalize(pass1[j + 1])
                var run = 1
                while j + 2 * (run + 1) <= pass1.count,
                      normalize(pass1[j + 2 * run]) == a,
                      normalize(pass1[j + 2 * run + 1]) == b { run += 1 }
                if run >= minRuns {
                    pass2.append(pass1[j])
                    pass2.append(pass1[j + 1])
                    j += 2 * run
                    continue
                }
            }
            pass2.append(pass1[j])
            j += 1
        }

        return pass2.joined(separator: " ")
    }

    /// Lowercase, punctuation → space, collapse whitespace. Accents are kept on
    /// purpose — folding them would hide real model errors (and "pólice" vs
    /// "police" is a distinction that matters in this domain).
    static func normalize(_ text: String) -> String {
        let mapped = text.unicodeScalars.map { scalar -> Character in
            if CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
            {
                return " "
            }
            return Character(scalar)
        }
        return String(mapped)
            .lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
