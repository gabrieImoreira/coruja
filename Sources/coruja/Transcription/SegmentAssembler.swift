import Foundation

/// Turns word-level timings into readable sentence segments.
///
/// This is what the Whisper path was missing and the Parakeet path already had
/// (see `ParakeetEngine.segments(from:)`). Without it, segments are whatever the
/// decoder happens to emit, which is why one spoken sentence lands as six or
/// eight lines with near-identical timestamps and the transcript is unreadable.
enum SegmentAssembler {
    struct TimedWord {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        /// Whisper's per-word probability, if available. Used only to compute a
        /// segment-level mean for an optional future LLM pass.
        let probability: Float?
    }

    struct Options {
        /// Silence between words that forces a break. 0.6 s is roughly the gap
        /// between sentences in conversational pt-BR; below ~0.4 s you split
        /// mid-clause, above ~1.0 s you glue separate turns together.
        var breakGap: TimeInterval = 0.6
        /// Hard caps so a run-on speaker still wraps.
        var maxWords = 45
        var maxDuration: TimeInterval = 18.0
        /// Don't break on punctuation before this many words — Whisper sprinkles
        /// commas and periods liberally, and breaking on every one recreates the
        /// fragmentation this type exists to fix.
        var minWordsBeforePunctuationBreak = 4
    }

    static func assemble(words: [TimedWord], options: Options = Options()) -> [Assembled] {
        var out: [Assembled] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { current = []; return }
            let probs = current.compactMap(\.probability)
            out.append(Assembled(
                start: first.start,
                end: last.end,
                text: text,
                meanWordProbability: probs.isEmpty ? nil : probs.reduce(0, +) / Float(probs.count)
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.start - last.end >= options.breakGap {
                flush()
            }
            current.append(word)

            let span = (current.last?.end ?? 0) - (current.first?.start ?? 0)
            let trimmed = word.text.trimmingCharacters(in: .whitespaces)
            let endsSentence = trimmed.hasSuffix(".") || trimmed.hasSuffix("?")
                || trimmed.hasSuffix("!") || trimmed.hasSuffix("…")

            if endsSentence, current.count >= options.minWordsBeforePunctuationBreak {
                flush()
            } else if current.count >= options.maxWords || span >= options.maxDuration {
                flush()
            }
        }
        flush()
        return out
    }

    struct Assembled {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let meanWordProbability: Float?
    }

    // MARK: - Fallback when word timings are unavailable

    /// Merge decoder segments when `wordTimestamps` produced nothing.
    ///
    /// Needed because WhisperKit does not error when the exported model lacks
    /// the `alignment_heads_weights` output — it silently returns `words == nil`
    /// (TranscribeTask.swift:199-201). Check
    /// `whisperKit.textDecoder.supportsWordTimestamps` up front, and keep this
    /// path for models that don't support it.
    static func merge(
        segments: [(start: TimeInterval, end: TimeInterval, text: String)],
        breakGap: TimeInterval = 0.6,
        maxDuration: TimeInterval = 18.0
    ) -> [Assembled] {
        var out: [Assembled] = []
        var buffer: (start: TimeInterval, end: TimeInterval, parts: [String])?

        func flush() {
            guard let b = buffer else { return }
            let text = b.parts.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                out.append(Assembled(start: b.start, end: b.end, text: text, meanWordProbability: nil))
            }
            buffer = nil
        }

        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            guard var b = buffer else {
                buffer = (seg.start, seg.end, [text])
                continue
            }

            let gap = seg.start - b.end
            let span = seg.end - b.start
            let previousEndsSentence = b.parts.last.map {
                $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!")
            } ?? false

            if gap >= breakGap || span >= maxDuration || previousEndsSentence {
                flush()
                buffer = (seg.start, seg.end, [text])
            } else {
                b.parts.append(text)
                b.end = seg.end
                buffer = b
            }
        }
        flush()
        return out
    }
}
