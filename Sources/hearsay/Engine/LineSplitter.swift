import Foundation

/// When each part of the model's hypothesis first appeared, in fed samples.
///
/// The models return a growing string with no per-word times we can use across every variant, so
/// the tracker records the sample count at which each stretch of text first showed up. "First
/// seen" minus the model's latency is a good estimate of when the words were spoken; it is what a
/// mid-speech split uses for the end of one line and the start of the next.
struct TextAges {
    /// Bytes `[previous run's end, end)` first appeared at `sample`. Both fields increase.
    private var runs: [(end: Int, sample: Int)] = []

    /// The hypothesis is now `newCount` bytes, of which the first `stable` bytes are unchanged.
    mutating func update(stable: Int, newCount: Int, at sample: Int) {
        var keepSample: Int?
        while let last = runs.last, last.end > stable { keepSample = last.sample; runs.removeLast() }
        if let s = keepSample, (runs.last?.end ?? 0) < stable { runs.append((stable, s)) }
        if newCount > (runs.last?.end ?? 0) { runs.append((newCount, sample)) }
    }

    /// Sample at which byte `offset` first appeared (`fallback` when unknown).
    func firstSeen(_ offset: Int, fallback: Int) -> Int {
        var lo = 0, hi = runs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if runs[mid].end > offset { hi = mid } else { lo = mid + 1 }
        }
        return lo < runs.count ? runs[lo].sample : fallback
    }

    /// Forgets bytes before `offset` (already committed).
    mutating func drop(below offset: Int) { runs.removeAll { $0.end <= offset } }
    mutating func reset() { runs = [] }
    var count: Int { runs.count }
}

/// Pure text analysis for splitting a long hypothesis into readable lines. Works on the UTF-8
/// bytes of the hypothesis so offsets are cheap to compare and slice; tokens are runs of
/// non-space bytes, so a split never lands inside a multi-byte character.
enum LineSplitter {
    struct Token { var start: Int; var end: Int }

    static func tokens(_ b: [UInt8], from: Int = 0, to: Int? = nil) -> [Token] {
        var out: [Token] = []
        var i = from
        let end = min(to ?? b.count, b.count)
        while i < end {
            while i < end, isSpace(b[i]) { i += 1 }
            let s = i
            while i < end, !isSpace(b[i]) { i += 1 }
            if i > s { out.append(Token(start: s, end: i)) }
        }
        return out
    }

    static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D }

    static func text(_ b: [UInt8], _ t: Token) -> String { String(decoding: b[t.start..<t.end], as: UTF8.self) }

    private static let closers: Set<Character> = ["\"", "'", ")", "”", "’", "]"]
    private static let openers: Set<Character> = ["\"", "'", "(", "“", "‘", "["]
    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "st", "vs", "jr", "sr", "no", "fig", "approx"]

    /// "done." "really?" "great!" "end.)" — but not "Mr." "e.g." "U.S." or a lone initial.
    static func endsSentence(_ word: String) -> Bool {
        var w = Substring(word)
        while let c = w.last, closers.contains(c) { w = w.dropLast() }
        guard let last = w.last, last == "." || last == "?" || last == "!" || last == "…" else { return false }
        if last != "." { return true }
        let stem = w.dropLast().lowercased()
        if stem.count <= 1 || stem.contains(".") || abbreviations.contains(stem) { return false }
        return true
    }

    /// The next token opens a sentence: starts (after an opening quote) with a capital or a digit.
    static func startsSentence(_ word: String) -> Bool {
        guard let c = word.first(where: { !openers.contains($0) }) else { return false }
        return c.isUppercase || c.isNumber
    }

    /// "however," "first;" "this:" or a dash on its own.
    static func endsClause(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return last == "," || last == ";" || last == ":" || word == "—" || word == "–" || word == "-"
    }

    /// Lower-cased letters and digits only, for comparing words across punctuation changes.
    static func normalized(_ word: Substring) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The model revised text we had already committed (punctuation, number formatting). Returns
    /// where the committed text ends in the new hypothesis: after the last few committed words,
    /// matched near the expected position; failing that, after the same number of words.
    static func realign(committed old: ArraySlice<UInt8>, in new: [UInt8]) -> Int {
        let oldWords = String(decoding: old, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(normalized)
        let toks = tokens(new)
        guard !oldWords.isEmpty, !toks.isEmpty else { return 0 }
        let newWords = toks.map { normalized(Substring(text(new, $0))) }
        let tail = Array(oldWords.suffix(3))
        let expected = oldWords.count - 1
        var best: Int?
        if tail.count <= newWords.count {
            for i in (tail.count - 1)..<newWords.count where Array(newWords[(i - tail.count + 1)...i]) == tail {
                if best == nil || abs(i - expected) < abs(best! - expected) { best = i }
            }
        }
        if let b = best, abs(b - expected) <= 6 { return toks[b].end }
        return toks[min(oldWords.count, toks.count) - 1].end
    }
}
