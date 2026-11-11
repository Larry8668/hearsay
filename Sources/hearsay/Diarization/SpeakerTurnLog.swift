import Foundation
import os

/// Speaker-turn diagnostics for one audio stream over one session, in the `diarize` log category:
///
///     them:app.zen-browser.zen: new speaker #3 settled at 12.4 s
///     them:app.zen-browser.zen: turn #2→#4 at 74.3 s, held 0.9 s settled
///     them:app.zen-browser.zen: tentative #4 at 74.1 s settled as #2
///     them:app.zen-browser.zen: summary · 4 speakers (#1 31.2 s, #2 20.4 s, #3 5.1 s, #4 1.2 s) · 12 turns · 7 tentative revisions (3 not logged)
///
/// WHY: "the captions said Speaker 4 but the file has none" is only answerable with who the
/// model heard when, and whether its look-ahead changed its mind. Nothing that was said reaches
/// these lines (slots, seconds and counts only), so they are on whatever the verbose setting.
/// Times are seconds since the session started. A flickery stream cannot flood the log: turn and
/// revision lines are each limited to one per `minInterval` (wall clock); the summary counts what
/// was held back.
///
/// The stream's engine worker writes; the registry reads the summary when the session ends.
final class SpeakerTurnLog: @unchecked Sendable {
    let stream: String
    /// Session start: "at 74.3 s" is measured from here.
    let origin: Date
    static let minInterval: TimeInterval = 1

    private enum Kind { case turn, revision }
    private struct Stats {
        var seconds: [Int: Double] = [:]
        var turns = 0
        var revisions = 0
        var suppressed = 0
        var lastLine: [Kind: Date] = [:]
    }
    private let stats = OSAllocatedUnfairLock(initialState: Stats())
    private let now: @Sendable () -> Date
    private let emit: @Sendable (String) -> Void

    init(stream: String, origin: Date, now: @escaping @Sendable () -> Date = { Date() },
         emit: @escaping @Sendable (String) -> Void = { Log.info(.diarize, $0) }) {
        self.stream = stream
        self.origin = origin
        self.now = now
        self.emit = emit
    }

    /// Frames that settled: `slot` (0-based) spoke for `seconds` from `at`. The first settled
    /// stretch of a slot is logged as a new speaker.
    func settled(slot: Int, seconds: Double, at: Date) {
        let first = stats.withLock { s -> Bool in
            defer { s.seconds[slot, default: 0] += seconds }
            return s.seconds[slot] == nil
        }
        if first { emit("\(stream): new speaker #\(slot + 1) settled at \(Self.secs(at.timeIntervalSince(origin)))") }
    }

    /// A line was cut on a speaker change.
    func turn(from: Int, to: Int, at: Date, held: Double) {
        guard admit(.turn, count: { $0.turns += 1 }) else { return }
        emit("\(stream): turn #\(from + 1)→#\(to + 1) at \(Self.secs(at.timeIntervalSince(origin))), held \(Self.secs(held)) settled")
    }

    /// The look-ahead named `tentative` for audio that settled as `settled`.
    func revised(tentative: Int, settled: Int, at: Date) {
        guard admit(.revision, count: { $0.revisions += 1 }) else { return }
        emit("\(stream): tentative #\(tentative + 1) at \(Self.secs(at.timeIntervalSince(origin))) settled as #\(settled + 1)")
    }

    /// The end-of-session line; nil when no speaker ever settled on this stream.
    func summary() -> String? {
        let s = stats.withLock { $0 }
        guard !s.seconds.isEmpty else { return nil }
        let per = s.seconds.keys.sorted().map { "#\($0 + 1) \(Self.secs(s.seconds[$0] ?? 0))" }.joined(separator: ", ")
        let n = s.seconds.count
        return "\(stream): summary · \(n) speaker\(n == 1 ? "" : "s") (\(per)) · \(s.turns) turn\(s.turns == 1 ? "" : "s") · "
            + "\(s.revisions) tentative revision\(s.revisions == 1 ? "" : "s")"
            + (s.suppressed > 0 ? " (\(s.suppressed) not logged)" : "")
    }

    /// Counts the event; true when its line may be written (none of its kind in the last second).
    private func admit(_ kind: Kind, count: (inout Stats) -> Void) -> Bool {
        let t = now()
        return stats.withLock { s in
            count(&s)
            if let last = s.lastLine[kind], t.timeIntervalSince(last) < Self.minInterval { s.suppressed += 1; return false }
            s.lastLine[kind] = t
            return true
        }
    }

    private static func secs(_ t: Double) -> String { String(format: "%.1f s", t) }
}
