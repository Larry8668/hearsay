import Foundation

/// Maps a position in the fed sample stream to wall-clock time.
///
/// Every fed chunk records an anchor (its first sample index + its `startTime`). We anchor per
/// chunk instead of assuming `firstChunk.startTime + n / 16 kHz` because capture clocks drift and
/// devices restart mid-session; the chunk timestamps are the source of truth.
struct SampleClock {
    private var anchors: [(sample: Int, date: Date)] = []
    private(set) var totalSamples = 0

    mutating func append(startTime: Date, sampleCount: Int) {
        anchors.append((totalSamples, startTime))
        totalSamples += sampleCount
    }

    /// Wall-clock time of `sample`. Before the first anchor it extrapolates backwards; past the
    /// end it extrapolates from the last anchor.
    func date(at sample: Int) -> Date {
        guard let first = anchors.first else { return Date() }
        // Binary search for the last anchor at or before `sample`.
        var lo = 0, hi = anchors.count - 1
        if sample < first.sample { return offset(first, sample) }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if anchors[mid].sample <= sample { lo = mid } else { hi = mid - 1 }
        }
        return offset(anchors[lo], sample)
    }

    /// Drops anchors that can no longer be asked about (everything before the one covering `sample`).
    /// Keeps memory flat over hours-long sessions (10 anchors/s otherwise).
    mutating func prune(before sample: Int) {
        guard let idx = anchors.lastIndex(where: { $0.sample <= sample }), idx > 0 else { return }
        anchors.removeFirst(idx)
    }

    var anchorCount: Int { anchors.count }

    private func offset(_ a: (sample: Int, date: Date), _ sample: Int) -> Date {
        a.date.addingTimeInterval(Double(sample - a.sample) / AudioChunk.sampleRate)
    }
}

/// Most common bundle id; ties go to the one seen first so the result is stable.
struct AppVotes {
    private var counts: [String: Int] = [:]
    private var order: [String] = []

    mutating func add(_ apps: [String]) {
        for app in apps where !app.isEmpty {
            if counts[app] == nil { order.append(app) }
            counts[app, default: 0] += 1
        }
    }

    var winner: String? {
        var best: String?
        for app in order where best == nil || counts[app]! > counts[best!]! { best = app }
        return best
    }

    mutating func reset() { counts = [:]; order = [] }
}

/// The model-independent half of an engine: decides WHEN a line is final, WHERE it is cut and
/// WHAT its timing and source app are. Pure (no CoreML), so it is unit-tested without models.
///
/// The model gives us a growing transcript string (append-only for the streaming managers, apart
/// from small revisions near the end). We remember how much of it has already been emitted as
/// final lines; the rest is the pending hypothesis. A line ends when:
///
/// - the speaker pauses (`silenceGap` below the energy threshold; tighter times than the model's
///   chunking, and the same for every variant), or the model signals end of utterance, or the
///   hypothesis stalls in a noisy room;
/// - the line is `sentenceAfter` old and contains a sentence end followed by a new sentence: it
///   is cut there and the rest stays pending (a video or a fast talker never pauses 1.2 s);
/// - the line reaches `clauseAfter` or `clauseWords` with no sentence end: cut at the last comma /
///   semicolon, else at a word boundary;
/// - `maxUtterance` as the last resort.
///
/// Mid-speech cuts never reset the model; only text that has been stable for `stableFor` is cut,
/// so a period the model is still revising is not committed. The cut's time comes from when the
/// text first appeared (`TextAges`) minus the model latency; the next line starts exactly there.
struct UtteranceTracker {
    struct Config {
        /// Audio below the energy threshold for this long ends a line.
        var silenceGap: TimeInterval = 1.2
        /// RMS over a 20 ms frame (Float32 −1…1). 0.006 ≈ −44 dBFS: above a quiet mic's noise
        /// floor, well below conversational speech (−30…−15 dBFS).
        var energyThreshold: Float = 0.006
        /// Force a line once the hypothesis spans this much audio, so captions never become a wall.
        var maxUtterance: TimeInterval = 25
        /// How far the model's output lags the audio (chunk + right context). Large-chunk tiers make
        /// the silence rule wait longer so words still inside the model's buffer are not cut off.
        var modelLatency: TimeInterval = 0.16
        /// A line this old is cut at its last sentence end.
        var sentenceAfter: TimeInterval = 7
        /// A line this old, or this many words, is cut at its last clause / word boundary.
        var clauseAfter: TimeInterval = 12
        var clauseWords = 40
        /// A clause cut leaves at least this many words on the line.
        var minLineWords = 4
        /// Only text unchanged for this long is cut mid-speech.
        var stableFor: TimeInterval = 1.0
    }

    enum Reason: String {
        case endOfUtterance, silence, stalled, sentence, clause, maxLength, flush
        /// Cut mid-speech: the model keeps running and the remainder stays pending.
        var isSplit: Bool { self == .sentence || self == .clause || self == .maxLength }
    }

    let config: Config
    private(set) var clock = SampleClock()
    private var votes = AppVotes()
    private static let frame = 320  // 20 ms at 16 kHz

    /// Sample index where the current (uncommitted) line's audio region begins.
    private(set) var lineOrigin = 0
    private(set) var firstVoiced: Int?
    private(set) var lastVoiced: Int?
    /// Full model transcript since the model was last reset, as UTF-8.
    private var hyp: [UInt8] = []
    /// Bytes of `hyp` already emitted as final lines.
    private(set) var committedOffset = 0
    private var ages = TextAges()
    private var lastTextChange = 0
    /// Times the model revised text that was already committed (realigned, see LineSplitter).
    private(set) var realignments = 0

    init(config: Config = Config()) { self.config = config }

    var samplesFed: Int { clock.totalSamples }
    var hypothesis: String { String(decoding: hyp, as: UTF8.self) }

    /// Text not yet emitted as a final line.
    var pending: String {
        guard committedOffset < hyp.count else { return "" }
        return String(decoding: hyp[committedOffset...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var lineStart: Int { firstVoiced ?? lineOrigin }

    mutating func ingest(_ chunk: AudioChunk) {
        let base = clock.totalSamples
        clock.append(startTime: chunk.startTime, sampleCount: chunk.samples.count)
        var voicedHere = false
        chunk.samples.withUnsafeBufferPointer { buf in
            var i = 0
            while i < buf.count {
                let n = min(Self.frame, buf.count - i)
                var sum: Float = 0
                for j in i..<(i + n) { sum += buf[j] * buf[j] }
                if (sum / Float(n)).squareRoot() >= config.energyThreshold {
                    if firstVoiced == nil { firstVoiced = base + i }
                    lastVoiced = base + i + n
                    voicedHere = true
                }
                i += n
            }
        }
        // Only voiced chunks vote: an app that is merely "playing" silence should not win the line.
        if voicedHere { votes.add(chunk.sourceApps) }
    }

    mutating func update(transcript: String) {
        let new = Array(transcript.utf8)
        guard new != hyp else { return }
        var common = 0
        let n = min(new.count, hyp.count)
        while common < n, new[common] == hyp[common] { common += 1 }
        if common < committedOffset {
            // Revised inside text we already emitted: find where that text ends now, so the next
            // line neither repeats nor loses words.
            committedOffset = LineSplitter.realign(committed: hyp[..<committedOffset], in: new)
            realignments += 1
        }
        ages.update(stable: common, newCount: new.count, at: samplesFed)
        hyp = new
        lastTextChange = samplesFed
    }

    /// Why the pending text should become a final line now, or nil to keep listening.
    func finalReason(modelSignalledEnd: Bool) -> Reason? {
        guard !pending.isEmpty else { return nil }
        if modelSignalledEnd { return .endOfUtterance }
        let rate = AudioChunk.sampleRate
        // The model must have decoded the last voiced audio before we cut. Within a 1.2 s gap the
        // small-chunk models already have; the 1–2 s chunk tiers need to wait a little longer.
        let wait = Int(max(config.silenceGap, config.modelLatency + 0.3) * rate)
        let quietSince = lastVoiced ?? lineOrigin
        if samplesFed - quietSince >= wait { return .silence }
        // Noisy rooms never drop below the threshold; a hypothesis that stopped growing for well
        // over a model chunk is the fallback end-of-line signal.
        if samplesFed - lastTextChange >= wait + Int((config.modelLatency + 1) * rate) { return .stalled }
        if let cut = splitPoint() { return cut.reason }
        if Double(samplesFed - lineStart) / rate >= config.maxUtterance { return .maxLength }
        return nil
    }

    /// Where to cut a long line mid-speech: the line keeps `[committedOffset, end)`, the next one
    /// starts at `next`. Nil while no rule applies or no stable boundary exists yet.
    func splitPoint() -> (reason: Reason, end: Int, next: Int)? {
        let rate = AudioChunk.sampleRate
        let age = Double(samplesFed - lineStart) / rate
        let toks = LineSplitter.tokens(hyp, from: committedOffset)
        let wantClause = age >= config.clauseAfter || toks.count >= config.clauseWords
        guard toks.count >= 2, wantClause || age >= config.sentenceAfter else { return nil }
        // Tokens appear in order, so the stable ones are a prefix. A cut after token i needs i+1
        // to be stable too (it proves the boundary: "simple." could still become "simple:").
        let stableBefore = samplesFed - Int(config.stableFor * rate)
        var stable = 0
        while stable < toks.count, ages.firstSeen(toks[stable].end - 1, fallback: samplesFed) <= stableBefore { stable += 1 }
        guard stable >= 2 else { return nil }
        let words = toks[..<stable].map { LineSplitter.text(hyp, $0) }
        for i in stride(from: stable - 2, through: 0, by: -1)
        where LineSplitter.endsSentence(words[i]) && LineSplitter.startsSentence(words[i + 1]) {
            return (.sentence, toks[i].end, toks[i + 1].start)
        }
        guard wantClause else { return nil }
        // A clause cut near the start would leave a stub line and the rest still too long.
        let minWords = max(config.minLineWords, stable * 2 / 5)
        if stable - 2 >= minWords - 1 {
            for i in stride(from: stable - 2, through: minWords - 1, by: -1) where LineSplitter.endsClause(words[i]) {
                return (.clause, toks[i].end, toks[i + 1].start)
            }
        }
        // No punctuation (a run-on): cut before a conjunction, else at the last stable word.
        if stable - 1 >= minWords {
            for j in stride(from: stable - 1, through: minWords, by: -1) where Self.joiners.contains(words[j].lowercased()) {
                return (.clause, toks[j - 1].end, toks[j].start)
            }
        }
        return (.clause, toks[stable - 2].end, toks[stable - 1].start)
    }

    private static let joiners: Set<String> = ["and", "but", "or", "so", "because", "which", "when", "while",
                                               "where", "including", "although", "though"]

    /// Builds the final line for the pending text and advances past it.
    /// - `modelWillReset`: the engine resets the model after this line (its transcript restarts
    ///   empty), so the committed prefix is cleared too. Split reasons expect `false`.
    mutating func commit(reason: Reason, speaker: Speaker, engine: String, modelWillReset: Bool) -> TranscriptLine? {
        var cut: (end: Int, next: Int)?
        if reason.isSplit, !modelWillReset {
            if reason != .maxLength, let p = splitPoint() {
                cut = (p.end, p.next)
            } else {
                // Length cap: the last word may still be growing ("under" → "understand"), hold it back.
                let toks = LineSplitter.tokens(hyp, from: committedOffset)
                if toks.count >= 2 { cut = (toks[toks.count - 2].end, toks[toks.count - 1].start) }
            }
        }
        let startSample = lineStart
        let textEnd = cut?.end ?? hyp.count
        let text = committedOffset < textEnd
            ? String(decoding: hyp[committedOffset..<textEnd], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        var endSample: Int
        if let cut {
            // When the last word of the line was spoken: when it showed up, minus the model's lag.
            let seen = ages.firstSeen(cut.end - 1, fallback: samplesFed)
            endSample = seen - Int(config.modelLatency * AudioChunk.sampleRate)
            endSample = min(max(endSample, startSample + 1), samplesFed)
        } else {
            endSample = max(startSample, reason == .maxLength ? samplesFed : (lastVoiced ?? samplesFed))
        }
        let line = text.isEmpty ? nil : TranscriptLine(
            speaker: speaker, sourceApp: votes.winner,
            start: clock.date(at: startSample), end: clock.date(at: endSample),
            text: text, engine: engine)

        if modelWillReset {
            hyp = []; committedOffset = 0; ages.reset()
        } else {
            committedOffset = cut?.next ?? hyp.count
            ages.drop(below: committedOffset)
        }
        lineOrigin = endSample
        // The remainder of a cut is speech in progress: it starts where this line ended.
        firstVoiced = cut != nil ? endSample : nil
        // …and is the same speech (often already spoken), so it keeps the app votes too.
        if cut == nil { lastVoiced = nil; votes.reset() }
        lastTextChange = samplesFed
        clock.prune(before: lineOrigin)
        return line
    }
}
