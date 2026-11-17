import Foundation

/// Scores transcript lines with speaker ids against a word-level reference (who said which word
/// when): the measuring stick of `hearsay --eval-speakers` (docs/EVAL-SPEAKERS.md). Pure, so the
/// definitions are unit-tested.
///
/// Words are aligned by text AND time: an edit-distance alignment (which also gives the WER) in
/// which a hypothesis word may only pair with a reference word spoken inside its line's span
/// (± `slack`). Lines carry no per-word times, so within a line words are spread over its span
/// in order. Each hypothesis speaker slot is mapped to at most one reference speaker, the
/// assignment that maximises correctly attributed words (exhaustive search: with ≤ 4 people and
/// ≤ 6 slots it is the Hungarian optimum without the bookkeeping); a slot left unmapped, and a
/// line without a speaker, count as wrong.
struct SpeakerScore: Equatable {
    struct RefWord: Equatable { var start: Double; var end: Double; var speaker: String; var text: String }
    struct HypLine: Equatable { var start: Double; var end: Double; var speaker: String?; var text: String }

    /// Reference words that paired with a hypothesis word (matches and substitutions).
    var aligned = 0
    /// Of those, attributed to the right person under the optimal slot mapping.
    var correct = 0
    var refWords = 0
    var substitutions = 0, deletions = 0, insertions = 0
    var lines = 0
    /// Reference turns (one person, word gaps < `turnGap`) with at least one aligned word.
    var turns = 0
    /// Turns whose words landed in lines of ≥ 2 different slots, and the words outside each
    /// such turn's main slot. `strictSplit` needs ≥ 2 words on each of two slots (one stray
    /// word is often an alignment artefact in overlapped speech).
    var splitTurns = 0, splitWords = 0, strictSplit = 0
    /// Lines holding words of ≥ 2 people, and the words of their minority speakers.
    var mergedLines = 0, mergedWords = 0
    /// Turns of ≤ `shortTurn` ("yeah", "right") and those whose words mostly landed in lines
    /// attributed to their speaker.
    var interjections = 0, interjectionsHit = 0

    static let turnGap = 1.0, shortTurn = 1.5, slack = 1.0

    var accuracy: Double { aligned == 0 ? 0 : Double(correct) / Double(aligned) }
    var wer: Double { refWords == 0 ? 0 : Double(substitutions + deletions + insertions) / Double(refWords) }
    var splitRate: Double { turns == 0 ? 0 : 100 * Double(splitTurns) / Double(turns) }
    var strictSplitRate: Double { turns == 0 ? 0 : 100 * Double(strictSplit) / Double(turns) }
    var interjectionRecall: Double { interjections == 0 ? 0 : Double(interjectionsHit) / Double(interjections) }

    /// Sums counts (each file keeps its own slot mapping).
    static func + (a: SpeakerScore, b: SpeakerScore) -> SpeakerScore {
        var s = a
        s.aligned += b.aligned; s.correct += b.correct; s.refWords += b.refWords
        s.substitutions += b.substitutions; s.deletions += b.deletions; s.insertions += b.insertions
        s.lines += b.lines; s.turns += b.turns
        s.splitTurns += b.splitTurns; s.splitWords += b.splitWords; s.strictSplit += b.strictSplit
        s.mergedLines += b.mergedLines; s.mergedWords += b.mergedWords
        s.interjections += b.interjections; s.interjectionsHit += b.interjectionsHit
        return s
    }

    /// Lowercased word tokens without punctuation; hyphenated words split ("kick-off" → kick off).
    static func normalize(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" }).compactMap { w in
            let t = String(w.filter { $0.isLetter || $0.isNumber || $0 == "'" })
            return t.isEmpty || t == "'" ? nil : t
        }
    }

    init() {}

    init(reference rawRef: [RefWord], lines rawLines: [HypLine]) {
        let ref = rawRef.flatMap { w in Self.normalize(w.text).map { RefWord(start: w.start, end: w.end, speaker: w.speaker, text: $0) } }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        let lines = rawLines.filter { !Self.normalize($0.text).isEmpty }.sorted { $0.start < $1.start }
        // Hypothesis words in order, each with its line and an estimated time.
        var hyp: [(text: String, line: Int, time: Double)] = []
        for (li, l) in lines.enumerated() {
            let ws = Self.normalize(l.text)
            for (k, w) in ws.enumerated() {
                hyp.append((w, li, l.start + (l.end - l.start) * (Double(k) + 0.5) / Double(ws.count)))
            }
        }
        refWords = ref.count
        self.lines = lines.count

        // Edit distance with a time window: ref word r may pair with hyp word h only if r is
        // spoken within h's line span ± slack.
        let n = ref.count, m = hyp.count
        let inf = Int32.max / 4
        var cost = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        var back = [UInt8](repeating: 0, count: (n + 1) * (m + 1))  // 1 diag, 2 up (deletion), 3 left (insertion)
        func idx(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
        for i in 1...max(n, 1) where i <= n { cost[idx(i, 0)] = Int32(i); back[idx(i, 0)] = 2 }
        for j in 1...max(m, 1) where j <= m { cost[idx(0, j)] = Int32(j); back[idx(0, j)] = 3 }
        if n > 0, m > 0 {
            for i in 1...n {
                let r = ref[i - 1], mid = (r.start + r.end) / 2
                for j in 1...m {
                    let h = hyp[j - 1], l = lines[h.line]
                    var best = inf, how: UInt8 = 0
                    if mid >= l.start - Self.slack, mid <= l.end + Self.slack {
                        best = cost[idx(i - 1, j - 1)] + (r.text == h.text ? 0 : 1); how = 1
                    }
                    let up = cost[idx(i - 1, j)] + 1, left = cost[idx(i, j - 1)] + 1
                    if up < best { best = up; how = 2 }
                    if left < best { best = left; how = 3 }
                    cost[idx(i, j)] = best; back[idx(i, j)] = how
                }
            }
        }
        var pairs: [(ref: Int, hyp: Int)] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            switch back[idx(i, j)] {
            case 1:
                if ref[i - 1].text != hyp[j - 1].text { substitutions += 1 }
                pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            case 2: deletions += 1; i -= 1
            default: insertions += 1; j -= 1
            }
        }
        pairs.reverse()
        aligned = pairs.count

        // Slot → person mapping that maximises correctly attributed words.
        let none = "–"
        func slot(_ h: Int) -> String { lines[hyp[h].line].speaker ?? none }
        var counts: [String: [String: Int]] = [:]
        for p in pairs { counts[slot(p.hyp), default: [:]][ref[p.ref].speaker, default: 0] += 1 }
        let people = Array(Set(ref.map(\.speaker))).sorted()
        let slots = counts.keys.filter { $0 != none }.sorted()
        let mapping = Self.bestMapping(slots: slots, people: people, counts: counts)
        func person(_ h: Int) -> String? { mapping[slot(h)] }
        correct = pairs.filter { person($0.hyp) == ref[$0.ref].speaker }.count

        // Reference turns: each person's words with gaps under `turnGap` (another voice talking
        // over them does not end their turn).
        var turnOf = [Int](repeating: -1, count: n)
        var turnBounds: [(start: Double, end: Double, speaker: String)] = []
        for p in people {
            var last: Double?
            for k in ref.indices where ref[k].speaker == p {
                if let e = last, ref[k].start - e < Self.turnGap {
                    turnBounds[turnBounds.count - 1].end = max(turnBounds[turnBounds.count - 1].end, ref[k].end)
                } else {
                    turnBounds.append((ref[k].start, ref[k].end, p))
                }
                turnOf[k] = turnBounds.count - 1
                last = max(last ?? ref[k].end, ref[k].end)
            }
        }
        var turnSlots = [[String: Int]](repeating: [:], count: turnBounds.count)
        var turnHits = [Int](repeating: 0, count: turnBounds.count)
        var lineRefs = [[String: Int]](repeating: [:], count: lines.count)
        for p in pairs {
            let t = turnOf[p.ref]
            turnSlots[t][slot(p.hyp), default: 0] += 1
            if person(p.hyp) == ref[p.ref].speaker { turnHits[t] += 1 }
            lineRefs[hyp[p.hyp].line][ref[p.ref].speaker, default: 0] += 1
        }
        for (t, b) in turnBounds.enumerated() {
            let total = turnSlots[t].values.reduce(0, +)
            guard total > 0 else { continue }
            turns += 1
            if turnSlots[t].count >= 2 {
                splitTurns += 1
                splitWords += total - (turnSlots[t].values.max() ?? 0)
                if turnSlots[t].values.filter({ $0 >= 2 }).count >= 2 { strictSplit += 1 }
            }
            if b.end - b.start <= Self.shortTurn {
                interjections += 1
                if 2 * turnHits[t] > total { interjectionsHit += 1 }
            }
        }
        for r in lineRefs where r.count >= 2 {
            mergedLines += 1
            mergedWords += r.values.reduce(0, +) - (r.values.max() ?? 0)
        }
    }

    /// The one-to-one slot → person assignment with the most agreeing words.
    static func bestMapping(slots: [String], people: [String], counts: [String: [String: Int]]) -> [String: String] {
        var best: [String: String] = [:], bestScore = -1
        var used = Set<String>(), current: [String: String] = [:]
        func search(_ k: Int, _ score: Int) {
            if k == slots.count {
                if score > bestScore { bestScore = score; best = current }
                return
            }
            search(k + 1, score)  // slot left unmapped
            for p in people where !used.contains(p) {
                used.insert(p); current[slots[k]] = p
                search(k + 1, score + (counts[slots[k]]?[p] ?? 0))
                used.remove(p); current[slots[k]] = nil
            }
        }
        search(0, 0)
        return best
    }
}
