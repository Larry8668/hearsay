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
/// - `maxUtterance` as the last resort;
/// - the speaker changes (`observe`): once a second voice has held the floor for `speakerHold`,
///   the first voice's words become a line of their own and the rest stays pending.
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
        /// A new speaker must hold the floor this long (their own frames) before a line is cut on
        /// the change; shorter runs are overlap, a "yes" in the background, or diarizer flicker.
        var speakerHold: TimeInterval = 0.6
    }

    enum Reason: String {
        case endOfUtterance, silence, stalled, sentence, clause, maxLength, flush, speakerChange
        /// Cut mid-speech: the model keeps running and the remainder stays pending.
        var isSplit: Bool { self == .sentence || self == .clause || self == .maxLength || self == .speakerChange }
    }

    let config: Config
    private(set) var clock = SampleClock()
    private var votes = AppVotes()
    /// App the line in progress is coming from, by voiced-chunk votes so far.
    var currentApp: String? { votes.winner }
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
    /// Who spoke when, from the lane's diarizer (lane samples, ascending). Finalized runs stay;
    /// the tentative ones (the model's look-ahead) are replaced by every update.
    private var speakerRuns: [SpeakerRun] = []
    private var tentativeRuns: [SpeakerRun] = []
    /// When each piece of `hyp` was spoken, in lane samples, from the model's own token timings:
    /// the model's text is its token pieces joined, so piece k covers bytes `[pieces[k−1].end,
    /// pieces[k].end)` of the hypothesis (`PieceTime.end`; the leading space of the first piece
    /// is trimmed away). `wordy` is false for a lone punctuation piece, which the RNN-T emits
    /// late: the "." of "then." arrives once the next speaker has started. Empty for models
    /// without timings; `TextAges` then stands in with a rougher estimate.
    struct PieceTime { var end: Int; var start: Int; var endSample: Int; var wordy: Bool }
    private var pieces: [PieceTime] = []

    init(config: Config = Config()) { self.config = config }

    var samplesFed: Int { clock.totalSamples }
    var hypothesis: String { String(decoding: hyp, as: UTF8.self) }

    /// Text not yet emitted as a final line.
    var pending: String {
        guard committedOffset < hyp.count else { return "" }
        return String(decoding: hyp[committedOffset...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var lineStart: Int { firstVoiced ?? lineOrigin }

    /// Returns whether the chunk had any voiced frame (callers gate the diarizer on it).
    @discardableResult
    mutating func ingest(_ chunk: AudioChunk) -> Bool {
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
        return voicedHere
    }

    // MARK: Word timings

    /// Appends the model's newest token pieces (text as it appears in the transcript, spoken
    /// span in lane samples).
    mutating func addPieceTimes(_ times: [(text: String, start: Int, end: Int)]) {
        for p in times {
            var bytes = Array(p.text.utf8)
            if pieces.isEmpty {
                bytes.removeFirst(bytes.prefix { LineSplitter.isSpace($0) }.count)
                if bytes.isEmpty { continue }
            }
            let end = (pieces.last?.end ?? 0) + bytes.count
            pieces.append(PieceTime(end: end, start: p.start, endSample: p.end,
                                    wordy: bytes.contains { $0 >= 0x30 && ($0 <= 0x39 || $0 >= 0x41) }))
        }
    }

    /// False once the pieces stop lining up with the hypothesis (a revision); the timings are
    /// then ignored rather than misapplied.
    var pieceTimesAligned: Bool { pieces.isEmpty || pieces.last?.end == hyp.count }

    /// Lane samples during which the token of `hyp` spanning bytes `[start, end)` was spoken,
    /// when the model told us: from its first piece (where the word begins) to its last lettered
    /// piece (a trailing "." is emitted much later, after the pause it ends). The RNN-T emits a
    /// piece near the end of its sound and the newest end is provisional, so the span is at least
    /// a frame long.
    private func spoken(tokenFrom start: Int, to end: Int) -> (start: Int, end: Int)? {
        guard !pieces.isEmpty, pieceTimesAligned else { return nil }
        var lo = 0, hi = pieces.count
        while lo < hi {   // first piece whose end is past `start`
            let mid = (lo + hi) / 2
            if pieces[mid].end > start { hi = mid } else { lo = mid + 1 }
        }
        guard lo < pieces.count else { return nil }
        var last = lo
        while last + 1 < pieces.count, pieces[last + 1].end <= end { last += 1 }
        while last > lo, !pieces[last].wordy { last -= 1 }
        return (pieces[lo].start, max(pieces[last].endSample, pieces[lo].start + Self.frame))
    }

    // MARK: Speakers

    mutating func observe(_ frames: SpeakerFrames) {
        for r in frames.finalized where r.end > r.start {
            if var last = speakerRuns.last, last.speaker == r.speaker, last.end == r.start {
                last.end = r.end
                speakerRuns[speakerRuns.count - 1] = last
            } else {
                speakerRuns.append(r)
            }
        }
        tentativeRuns = frames.tentative
    }

    /// Slot that spoke most of `[from, to)`; nil when no slot was active there.
    func dominantSpeaker(from: Int, to: Int) -> Int? {
        var held: [Int: Int] = [:]
        for r in speakerRuns + tentativeRuns {
            let a = max(r.start, from), b = min(r.end, to)
            if b > a { held[r.speaker, default: 0] += b - a }
        }
        // Ties go to the lower slot, so the choice is stable from one call to the next.
        return held.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    /// Who is talking right now, for partials: whoever dominated the last `speakerHold`, else
    /// the line so far. The short window switches captions promptly without reacting to flicker.
    var currentSpeaker: Int? {
        let window = Int(config.speakerHold * AudioChunk.sampleRate)
        return dominantSpeaker(from: max(lineStart, samplesFed - window), to: samplesFed)
            ?? dominantSpeaker(from: lineStart, to: samplesFed)
    }

    /// The lane sample at which the current line's speaker changed, once the newcomer has held
    /// the floor for `speakerHold` of finalized frames (gaps of silence inside their streak are
    /// fine; the tentative look-ahead still flickers in the first seconds of a session) and the
    /// speech model has had time to emit the previous speaker's last words. Nil while the line
    /// has one speaker, or the earlier voice was too brief to deserve a line.
    func speakerTurn() -> Int? {
        let runs = speakerRuns.filter { $0.end > lineStart }
        guard let last = runs.last else { return nil }
        let rate = AudioChunk.sampleRate
        var i = runs.count - 1, held = 0, streakStart = max(last.start, lineStart)
        while i >= 0, runs[i].speaker == last.speaker {
            held += runs[i].end - max(runs[i].start, lineStart)
            streakStart = max(runs[i].start, lineStart)
            i -= 1
        }
        guard Double(held) / rate >= config.speakerHold,
              Double(samplesFed - streakStart) / rate >= max(config.speakerHold, config.modelLatency + 0.4),
              let before = dominantSpeaker(from: lineStart, to: streakStart), before != last.speaker else { return nil }
        var beforeHeld = 0
        for r in runs where r.speaker == before { beforeHeld += max(0, min(r.end, streakStart) - max(r.start, lineStart)) }
        guard Double(beforeHeld) / rate >= config.speakerHold else { return nil }
        return streakStart
    }

    /// Who said a word first seen at `seen`: the slot that dominated the model's last chunk
    /// before then, `[seen − latency − 0.3 s, seen − 0.08 s)`. A pause of 0.3 s or more inside
    /// that window means the model held the word back until it was sure the utterance had ended
    /// (the last word before a turn always arrives late), so the word came before the pause.
    private func speakerHeard(before seen: Int) -> Int? {
        let rate = AudioChunk.sampleRate
        let from = seen - Int((config.modelLatency + 0.3) * rate), to = seen - Int(0.08 * rate)
        var cutoff = to
        var lastEnd: Int?
        for r in speakerRuns + tentativeRuns {
            let a = max(r.start, from), b = min(r.end, to)
            guard b > a else { continue }
            if let e = lastEnd, a - e >= Int(0.3 * rate) { cutoff = e; break }
            lastEnd = b
        }
        return dominantSpeaker(from: from, to: cutoff)
    }

    /// Where to cut on a speaker change: the line keeps `[committedOffset, end)`, the next one
    /// starts at `next`, both ending / starting at lane sample `at`. Words go to whoever the
    /// diarizer heard when they were spoken (`speakerHeard`); the first word that is the
    /// newcomer's starts their line. `end == next ==
    /// hyp.count` means every pending word was the first speaker's (the newcomer's have not
    /// shown up yet), `end == next == committedOffset` that none of the first speaker's speech
    /// was transcribed. Nil while the first speaker's last word may still change: its full stop
    /// arrives a second or more after the word, once the model has heard the pause.
    func speakerCut() -> (end: Int, next: Int, at: Int)? {
        guard let at = speakerTurn() else { return nil }
        let rate = AudioChunk.sampleRate
        let toks = LineSplitter.tokens(hyp, from: committedOffset)
        guard !toks.isEmpty, let new = dominantSpeaker(from: at, to: samplesFed) else { return nil }
        let latency = Int(config.modelLatency * rate)
        var before = 0
        while before < toks.count {
            let who: Int?
            if let w = spoken(tokenFrom: toks[before].start, to: toks[before].end) {
                // The emission sits at the word's end: whoever was heard just before it said it.
                who = dominantSpeaker(from: w.start - Int(0.25 * rate), to: w.end)
                    ?? dominantSpeaker(from: w.start - Int(0.6 * rate), to: w.end) ?? (w.start <= at ? -1 : new)
            } else {
                let seen = ages.firstSeen(toks[before].end - 1, fallback: samplesFed)
                who = speakerHeard(before: seen) ?? (seen - latency / 2 <= at ? -1 : new)
            }
            if who == new { break }
            before += 1
        }
        if before == 0 { return (committedOffset, committedOffset, at) }
        guard ages.firstSeen(toks[before - 1].end - 1, fallback: samplesFed) <= samplesFed - Int(config.stableFor * rate) else { return nil }
        if before == toks.count { return (hyp.count, hyp.count, at) }
        return (toks[before - 1].end, toks[before].start, at)
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
        if speakerCut() != nil { return .speakerChange }
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
    /// - `stream`: the audio stream's key ("me", "them:us.zoom.xos") that turns the dominant
    ///   diarizer slot into the line's `speakerID`; nil leaves the line without one.
    mutating func commit(reason: Reason, speaker: Speaker, engine: String, modelWillReset: Bool,
                         stream: String? = nil) -> TranscriptLine? {
        var cut: (end: Int, next: Int)?
        var cutAt: Int?
        if reason.isSplit, !modelWillReset {
            if reason == .speakerChange, let c = speakerCut() {
                cut = (c.end, c.next); cutAt = c.at
            } else if reason != .maxLength, reason != .speakerChange, let p = splitPoint() {
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
        if let cutAt {
            endSample = min(max(cutAt, startSample + 1), samplesFed)
        } else if let cut {
            // When the last word of the line was spoken: from the model's timing when it has one,
            // else when the word showed up minus the model's lag.
            if let w = spoken(tokenFrom: LineSplitter.tokens(hyp, to: cut.end).last?.start ?? committedOffset, to: cut.end) {
                endSample = w.end
            } else {
                let seen = ages.firstSeen(cut.end - 1, fallback: samplesFed)
                endSample = seen - Int(config.modelLatency * AudioChunk.sampleRate)
            }
            endSample = min(max(endSample, startSample + 1), samplesFed)
        } else {
            endSample = max(startSample, reason == .maxLength ? samplesFed : (lastVoiced ?? samplesFed))
        }
        let speakerID = stream.flatMap { s in dominantSpeaker(from: startSample, to: endSample).map { SpeakerID.make(stream: s, slot: $0) } }
        // A stray full stop (punctuation the model added after its word was cut away) is no line.
        let line = !text.contains(where: { $0.isLetter || $0.isNumber }) ? nil : TranscriptLine(
            speaker: speaker, sourceApp: votes.winner,
            start: clock.date(at: startSample), end: clock.date(at: endSample),
            text: text, engine: engine, speakerID: speakerID)

        if modelWillReset {
            hyp = []; committedOffset = 0; ages.reset(); pieces = []
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
        speakerRuns.removeAll { $0.end <= lineOrigin }
        return line
    }
}
