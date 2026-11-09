import Foundation

/// Text-level backstop against acoustic echo: when the far side plays through speakers and the
/// microphone hears it, the "me" lane transcribes a degraded copy of what the "them" lane already
/// has. Echo cancellation (MicCapture) removes most of it; this catches the rest by comparing a
/// "me" line's words with "them" text from the same moment and dropping it when they overlap.
/// Only the mic lane is filtered: the system tap can't hear the room.
struct EchoFilter {
    /// Fraction of a me-line's words that must appear in overlapping them-text to call it echo.
    var threshold = 0.6
    /// How far apart in time the two can be and still be the same utterance (speaker→mic→model
    /// delays plus the engines' different end-of-line timing).
    var slack: TimeInterval = 4

    private struct Recent { var start: Date; var end: Date; var words: Set<String> }
    private var them: [Recent] = []

    /// Register them-text (final lines and partials) so later me-lines can be compared.
    mutating func observeThem(text: String, start: Date, end: Date) {
        let w = EchoFilter.words(text)
        guard !w.isEmpty else { return }
        them.append(Recent(start: start, end: end, words: w))
        let cutoff = end.addingTimeInterval(-60)
        them.removeAll { $0.end < cutoff }
    }

    /// True when `text` from the mic between `start`…`end` is an echo of recent them-text.
    func isEcho(text: String, start: Date, end: Date) -> Bool {
        let mine = EchoFilter.words(text)
        guard mine.count >= 3 else { return false }   // too short to judge ("yes", "okay")
        var pool = Set<String>()
        for r in them where r.end >= start.addingTimeInterval(-slack) && r.start <= end.addingTimeInterval(slack) {
            pool.formUnion(r.words)
        }
        guard !pool.isEmpty else { return false }
        let hits = mine.filter { pool.contains($0) }.count
        return Double(hits) / Double(mine.count) >= threshold
    }

    /// Lower-cased alphanumeric words, minus the few function words that match by chance.
    static func words(_ text: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "and", "to", "of", "i", "it", "is", "in", "that", "we", "you", "so"]
        var out = Set<String>()
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let w = String(raw)
            if w.count > 1, !stop.contains(w) { out.insert(w) }
        }
        return out
    }
}
