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

/// The model-independent half of an engine: decides WHEN a line is final and WHAT its timing and
/// source app are. Pure (no CoreML), so it is unit-tested without models.
///
/// The model gives us a growing transcript string (append-only for the streaming Parakeet /
/// Nemotron managers). We remember which prefix has already been emitted as final lines; the rest
/// is the pending hypothesis. Line boundaries come from a simple energy detector because it works
/// the same for every variant and gives tighter start/end times than chunk boundaries.
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
    }

    enum Reason: String { case endOfUtterance, silence, stalled, maxLength, flush }

    let config: Config
    private(set) var clock = SampleClock()
    private var votes = AppVotes()
    private static let frame = 320  // 20 ms at 16 kHz

    /// Sample index where the current (uncommitted) line's audio region begins.
    private(set) var lineOrigin = 0
    private(set) var firstVoiced: Int?
    private(set) var lastVoiced: Int?
    /// Full model transcript since the model was last reset.
    private(set) var hypothesis = ""
    /// Prefix of `hypothesis` already emitted as final lines.
    private(set) var committed = ""
    private var lastTextChange = 0

    init(config: Config = Config()) { self.config = config }

    var samplesFed: Int { clock.totalSamples }

    /// Text not yet emitted as a final line.
    var pending: String {
        let tail = hypothesis.hasPrefix(committed)
            ? String(hypothesis.dropFirst(committed.count))
            : String(hypothesis.dropFirst(min(committed.count, hypothesis.count)))
        return tail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
        if transcript != hypothesis {
            hypothesis = transcript
            lastTextChange = samplesFed
        }
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
        if Double(samplesFed - (firstVoiced ?? lineOrigin)) / rate >= config.maxUtterance { return .maxLength }
        return nil
    }

    /// Builds the final line for the pending text and advances past it.
    /// - `modelWillReset`: the engine resets the model after this line (its transcript restarts
    ///   empty), so the committed prefix is cleared too.
    mutating func commit(reason: Reason, speaker: Speaker, engine: String, modelWillReset: Bool) -> TranscriptLine? {
        var text = pending
        var advanceTo = hypothesis
        if reason == .maxLength, !modelWillReset, let cut = text.lastIndex(of: " ") {
            // Mid-speech cut: the last word may still be growing ("under" → "understand"), so hold
            // it back for the next line.
            text = String(text[..<cut])
            let held = pending.distance(from: cut, to: pending.endIndex)
            advanceTo = String(hypothesis.dropLast(held))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let startSample = firstVoiced ?? lineOrigin
        let endSample = max(startSample, (reason == .maxLength ? samplesFed : (lastVoiced ?? samplesFed)))
        let line = text.isEmpty ? nil : TranscriptLine(
            speaker: speaker, sourceApp: votes.winner,
            start: clock.date(at: startSample), end: clock.date(at: endSample),
            text: text, engine: engine)

        committed = modelWillReset ? "" : advanceTo
        if modelWillReset { hypothesis = "" }
        lineOrigin = reason == .maxLength ? samplesFed : endSample
        firstVoiced = nil
        lastVoiced = nil
        lastTextChange = samplesFed
        votes.reset()
        clock.prune(before: lineOrigin)
        return line
    }
}
