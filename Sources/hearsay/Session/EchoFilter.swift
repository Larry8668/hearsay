import Foundation

/// Text-level backstop against acoustic echo: when the far side plays through speakers and the
/// microphone hears it, the "me" lane transcribes a degraded copy of what the "them" lane already
/// has. Echo cancellation (MicCapture) removes most of it; this catches the rest. The only precise
/// signal is the same words on both lanes at the same moment, so that is what it compares; levels
/// only break ties. Only the mic lane is filtered: the system tap can't hear the room.
///
/// Rules (a me-line sharing < `minOverlap` of its words with them-text is NEVER dropped):
/// 1. me-partials: the whole partial, or its last `tailWords` words, ≥ `threshold` in recent
///    them-text (last `poolWindow`) → hidden while it lasts.
/// 2. me-final ≥ `threshold` in them-text from the same time (± `slack`) → dropped.
/// 3. me-final of ≤ 2 words with a word in them-text within ± `fragmentSlack` → dropped (AEC
///    residue: "However", "Q3"), unless the levels say the mic was about as loud as them.
/// 4. me-final ≥ `minOverlap` and most of its partials were echo → dropped.
/// 5. me-final ≥ `minOverlap` and the mic was ≥ `levelGap` dB quieter than them → dropped.
///
/// Pure value type; SessionController feeds it and acts on the verdicts.
struct EchoFilter {
    var threshold = 0.5
    var minOverlap = 0.3
    /// How far apart in time the two can be and still be the same utterance (speaker→mic→model
    /// delays plus the engines' different end-of-line timing).
    var slack: TimeInterval = 4
    var fragmentSlack: TimeInterval = 2
    var tailWords = 8
    var poolWindow: TimeInterval = 30
    /// A them-partial covers at most this much audio (the engine cuts lines at 7–12 s, 25 s at most).
    var partialSpan: TimeInterval = 25
    var levelGap: Double = 12
    /// A short me-line this close to (or louder than) them in level is someone actually talking.
    var fragmentKeepGap: Double = 6

    enum Verdict: Equatable {
        case keep
        case echo(String)   // why, for the log
    }

    private struct Recent { var start: Date; var end: Date; var words: Set<String> }
    private var finals: [Recent] = []
    private var partial: Recent?
    /// me-partials of the line in progress: how many were checked and how many were echo.
    private var meChecked = 0
    private var meEcho = 0

    // MARK: them

    mutating func observeThemFinal(text: String, start: Date, end: Date) {
        partial = nil
        let w = Set(Self.words(text))
        guard !w.isEmpty else { return }
        finals.append(Recent(start: start, end: end, words: w))
        let cutoff = end.addingTimeInterval(-2 * poolWindow)
        finals.removeAll { $0.end < cutoff }
    }

    /// The them-lane's current hypothesis (nil / empty when it has none). Partials carry no times:
    /// it started when it first appeared, but never more than `partialSpan` ago.
    mutating func observeThemPartial(text: String?, now: Date) {
        let w = Set(Self.words(text ?? ""))
        guard !w.isEmpty else { partial = nil; return }
        let start = max(partial?.start ?? now, now.addingTimeInterval(-partialSpan))
        partial = Recent(start: start, end: now, words: w)
    }

    // MARK: me

    /// True when the me-partial looks like echo (hide it). Also tallied for the final's verdict.
    mutating func checkMePartial(text: String, now: Date) -> Bool {
        let mine = Self.words(text)
        guard !mine.isEmpty else { return false }
        let pool = self.pool(from: now.addingTimeInterval(-poolWindow), to: now)
        guard !pool.isEmpty else { meChecked += 1; return false }
        let tail = Array(mine.suffix(tailWords))
        let echo: Bool
        if mine.count == 1 {
            // A lone word only counts while them is talking right now (see rule 3).
            let recent = self.pool(from: now.addingTimeInterval(-fragmentSlack), to: now)
            echo = recent.contains(mine[0])
        } else {
            echo = Self.overlap(mine, pool) >= threshold || (tail.count >= 3 && Self.overlap(tail, pool) >= threshold)
        }
        meChecked += 1
        if echo { meEcho += 1 }
        return echo
    }

    /// Decides a me-final. `levelGap`: them-lane level minus me-lane level over the line, in dB
    /// (positive = mic quieter), nil when unknown. Resets the partial tally for the next line.
    mutating func checkMeFinal(text: String, start: Date, end: Date, levelGap gap: Double?) -> Verdict {
        defer { meChecked = 0; meEcho = 0 }
        let mine = Self.words(text)
        guard !mine.isEmpty else { return .keep }
        let rawCount = text.split(whereSeparator: { $0.isWhitespace }).count
        if rawCount <= 2 {
            let near = pool(from: start.addingTimeInterval(-fragmentSlack), to: end.addingTimeInterval(fragmentSlack))
            guard Self.overlap(mine, near) >= minOverlap else { return .keep }
            if let gap, gap < fragmentKeepGap { return .keep }
            return .echo("short fragment while them was talking")
        }
        let pool = self.pool(from: start.addingTimeInterval(-slack), to: end.addingTimeInterval(slack))
        let share = Self.overlap(mine, pool)
        guard share >= minOverlap else { return .keep }
        let pct = Int((share * 100).rounded())
        if share >= threshold { return .echo("\(pct)% of words match them") }
        if meChecked >= 2, meEcho * 2 > meChecked { return .echo("\(pct)% match, \(meEcho)/\(meChecked) partials were echo") }
        if let gap, gap >= levelGap { return .echo("\(pct)% match, mic \(Int(gap.rounded())) dB below them") }
        return .keep
    }

    /// Forget the me-partial tally (pause / stop: the line in progress will not get a final).
    mutating func resetMe() { meChecked = 0; meEcho = 0 }

    // MARK: helpers

    /// Words of them-text whose time range overlaps `from…to`.
    private func pool(from: Date, to: Date) -> Set<String> {
        var out = Set<String>()
        for r in finals where r.end >= from && r.start <= to { out.formUnion(r.words) }
        if let p = partial, p.end >= from, p.start <= to { out.formUnion(p.words) }
        return out
    }

    static func overlap(_ mine: [String], _ pool: Set<String>) -> Double {
        guard !mine.isEmpty else { return 0 }
        return Double(mine.filter { pool.contains($0) }.count) / Double(mine.count)
    }

    private static let stop: Set<String> = ["the", "a", "an", "and", "to", "of", "i", "it", "is", "in", "that", "we", "you", "so"]

    /// Lower-cased alphanumeric words in order, minus the few function words that match by chance.
    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap { raw in
            let w = String(raw)
            return w.count > 1 && !stop.contains(w) ? w : nil
        }
    }
}
