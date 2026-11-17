import FluidAudio
import Foundation

/// `hearsay --eval-speakers DIR [--diarize KIND] [--realtime] [--only NAME] [--dump DIR]
///  [tracker flags, see `TrackerFlags`]`
///
/// Runs the live pipeline (speech model + diarizer + `UtteranceTracker`, exactly as a microphone
/// session) over every `NAME.wav` in DIR that has a `NAME.words.tsv` reference beside it, and
/// scores the lines with `SpeakerScore`. Fed as fast as the models run; the tracker counts lane
/// samples, never the wall clock, so the lines are the same as with `--realtime` (checked; see
/// docs/EVAL-SPEAKERS.md). No enrolment clip and no stored preference is used: the variant and
/// diarizer are the defaults unless given. CLI only; its output IS the product, so it prints.
enum SpeakerEval {
    static func run(arguments: [String]) -> Int32 {
        var dir: String?, kind = DiarizerKind.default, realtime = false, only: [String] = [], dump: String?, rescore: String?
        var cfg = UtteranceTracker.Config(), variant = ParakeetEngine.defaultVariant
        var it = arguments.makeIterator()
        while let a = it.next() {
            if TrackerFlags.apply(a, &it, to: &cfg) { continue }
            switch a {
            case "--diarize":
                guard let raw = it.next(), let k = DiarizerKind(rawValue: raw) else { print("--diarize needs a kind"); return 2 }
                kind = k
            case "--realtime": realtime = true
            case "--only": if let n = it.next() { only.append(n) }
            case "--dump": dump = it.next()
            case "--rescore": rescore = it.next()
            case "--variant":
                guard let raw = it.next(), let v = StreamingModelVariant(rawValue: raw) else { print("unknown variant"); return 2 }
                variant = v
            default: dir = a
            }
        }
        guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            print("usage: hearsay --eval-speakers DIR [--diarize KIND] [--realtime] [--only NAME] [--dump DIR] \(TrackerFlags.usage)")
            return 2
        }
        let meetings = names.filter { $0.hasSuffix(".wav") }.map { String($0.dropLast(4)) }.sorted()
            .filter { names.contains("\($0).words.tsv") && (only.isEmpty || only.contains($0)) }
        guard !meetings.isEmpty else { print("\(dir): no NAME.wav with NAME.words.tsv"); return 2 }
        print("config: \(TrackerFlags.describe(cfg)), diarizer \(kind.rawValue)\(realtime ? ", realtime" : "")")

        let sem = DispatchSemaphore(value: 0)
        let code = Box()
        Task.detached {
            code.value = await evaluate(dir: dir, meetings: meetings, kind: kind, variant: variant, cfg: cfg,
                                        realtime: realtime, dump: dump, rescore: rescore)
            sem.signal()
        }
        sem.wait()
        return code.value
    }

    private final class Box: @unchecked Sendable { var value: Int32 = 0 }

    private static func evaluate(dir: String, meetings: [String], kind: DiarizerKind, variant: StreamingModelVariant,
                                 cfg: UtteranceTracker.Config, realtime: Bool, dump: String?, rescore: String?) async -> Int32 {
        await DiarizerRegistry.shared.configure(mode: .microphone, kind: kind, clip: nil)
        let engine = ParakeetEngine(variant: variant, tracker: cfg)
        if rescore == nil {
            do {
                try await DiarizerRegistry.shared.prepare { _ in }
                try await engine.prepare { _ in }
            } catch {
                print("prepare failed: \(error.localizedDescription)"); return 1
            }
        }
        print("file       acc    split/100  strict  splitW  merged mergedW  interj      lines cuts  WER    lag")
        var total = SpeakerScore(), cuts = 0, lags: [Double] = []
        let t0 = Date()
        for m in meetings {
            guard case .success(let audio) = WAV.read("\(dir)/\(m).wav"),
                  let ref = readReference("\(dir)/\(m).words.tsv") else { print("\(m): unreadable"); return 2 }
            // --rescore: the lines of an earlier --dump (cuts unknown), for rules applied after the fact.
            var r: (lines: [SpeakerScore.HypLine], cuts: Int, lags: [Double])
            if let rescore {
                r = (readLines("\(rescore)/\(m).lines.tsv"), 0, [])
            } else {
                guard let s = await session(engine: engine, audio: audio, realtime: realtime) else { return 1 }
                r = s
            }
            if let rule = cfg.smoothABA {
                // Scored as the look-ahead would emit them: the decision needs only the next line.
                let who = SpeakerSmoothing.relabelABA(r.lines.map {
                    .init(start: $0.start, end: $0.end, speaker: $0.speaker, words: SpeakerScore.normalize($0.text).count)
                }, rule: rule)
                for i in r.lines.indices { r.lines[i].speaker = who[i] }
            }
            let score = SpeakerScore(reference: ref, lines: r.lines)
            total = total + score
            cuts += r.cuts
            lags += r.lags
            print(row(m, score, cuts: r.cuts, lags: r.lags))
            if let dump {
                let tsv = r.lines.map { String(format: "%.3f\t%.3f\t%@\t%@", $0.start, $0.end, $0.speaker ?? "-", $0.text) }
                try? (tsv.joined(separator: "\n") + "\n").write(toFile: "\(dump)/\(m).lines.tsv", atomically: true, encoding: .utf8)
            }
        }
        print(row("ALL", total, cuts: cuts, lags: lags))
        print(String(format: "wall %.0f s", Date().timeIntervalSince(t0)))
        return 0
    }

    private static func row(_ name: String, _ s: SpeakerScore, cuts: Int, lags: [Double]) -> String {
        let lag = lags.isEmpty ? "–" : String(format: "%.2f", lags.reduce(0, +) / Double(lags.count))
        return String(format: "%@ %5.1f%%  %5.1f (%3d)  %5.1f  %5d  %5d  %5d   %5.1f%% (%3d)  %4d  %4d  %4.1f%%  %@",
                      name.padding(toLength: 9, withPad: " ", startingAt: 0), 100 * s.accuracy, s.splitRate, s.splitTurns, s.strictSplitRate, s.splitWords,
                      s.mergedLines, s.mergedWords, 100 * s.interjectionRecall, s.interjections,
                      s.lines, cuts, 100 * s.wer, lag)
    }

    /// One microphone session over `audio`: the lines (seconds from the start), speaker-change
    /// cuts, and (realtime) how long after its end each line arrived.
    private static func session(engine: ParakeetEngine, audio: [Float], realtime: Bool)
        async -> (lines: [SpeakerScore.HypLine], cuts: Int, lags: [Double])? {
        let t0 = Date()
        await DiarizerRegistry.shared.beginSession(at: t0)
        guard let events = try? await engine.start(speaker: .me, stream: "me") else { print("start failed"); return nil }
        let listener = Task.detached { () -> ([SpeakerScore.HypLine], [Double]) in
            var lines: [SpeakerScore.HypLine] = [], lags: [Double] = []
            for await ev in events {
                guard case .final(let l) = ev else { continue }
                lags.append(Date().timeIntervalSince(l.end))
                lines.append(.init(start: l.start.timeIntervalSince(t0), end: l.end.timeIntervalSince(t0),
                                   speaker: l.speakerID, text: l.text))
            }
            return (lines, lags)
        }
        let chunk = 1600
        var offset = 0
        while offset < audio.count {
            let slice = Array(audio[offset..<min(offset + chunk, audio.count)])
            await engine.feed(AudioChunk(samples: slice, startTime: t0.addingTimeInterval(Double(offset) / AudioChunk.sampleRate),
                                         speaker: .me, sourceApps: []))
            offset += chunk
            if realtime {
                let wait = t0.addingTimeInterval(Double(offset) / AudioChunk.sampleRate).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            }
        }
        await engine.stop()
        let cuts = await DiarizerRegistry.shared.turnLog(for: "me")?.counts.turns ?? 0
        await DiarizerRegistry.shared.endSession()
        let (lines, lags) = await listener.value
        return (lines, cuts, realtime ? lags : [])
    }

    /// A `--dump` file: `start<TAB>end<TAB>speaker or -<TAB>text`.
    static func readLines(_ path: String) -> [SpeakerScore.HypLine] {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { row in
            let f = row.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard f.count == 4, let s = Double(f[0]), let e = Double(f[1]) else { return nil }
            return .init(start: s, end: e, speaker: f[2] == "-" ? nil : String(f[2]), text: String(f[3]))
        }
    }

    /// `start<TAB>end<TAB>speaker<TAB>word` per line (scripts/ami-eval-prep.py).
    static func readReference(_ path: String) -> [SpeakerScore.RefWord]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").compactMap { row in
            let f = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 4, let s = Double(f[0]), let e = Double(f[1]) else { return nil }
            return .init(start: s, end: e, speaker: String(f[2]), text: String(f[3]))
        }
    }
}

/// Tracker settings the CLI can override (`--transcribe`, `--eval-speakers`), so a candidate
/// rule is measured without a rebuild.
enum TrackerFlags {
    static let usage = "[--speaker-hold S] [--word-lead S] [--silence-gap S] [--cut-at-pause [--cut-pause S] [--cut-window S]] [--smooth-aba [--aba-words N] [--aba-seconds S] [--aba-gap S]]"

    /// Applies flag `a` (reading its value from `it`); false when `a` is not a tracker flag.
    static func apply(_ a: String, _ it: inout IndexingIterator<[String]>, to cfg: inout UtteranceTracker.Config) -> Bool {
        func value(_ old: Double) -> Double { Double(it.next() ?? "") ?? old }
        var aba = cfg.smoothABA ?? SpeakerSmoothing.Rule()
        switch a {
        case "--speaker-hold": cfg.speakerHold = value(cfg.speakerHold)
        case "--word-lead": cfg.wordLead = value(cfg.wordLead)
        // Not a speaker rule: nudging it shows how much the scores move when only the timing of
        // model resets changes (the noise floor any speaker rule's effect must clear).
        case "--silence-gap": cfg.silenceGap = value(cfg.silenceGap)
        case "--cut-at-pause": cfg.cutAtPause = true
        case "--cut-pause": cfg.cutPause = value(cfg.cutPause)
        case "--cut-window": cfg.cutPauseWindow = value(cfg.cutPauseWindow)
        case "--smooth-aba": break
        case "--aba-words": aba.maxWords = Int(value(Double(aba.maxWords)))
        case "--aba-seconds": aba.maxSeconds = value(aba.maxSeconds)
        case "--aba-gap": aba.maxGap = value(aba.maxGap)
        default: return false
        }
        if a.hasPrefix("--aba") || a == "--smooth-aba" { cfg.smoothABA = aba }
        return true
    }

    static func describe(_ c: UtteranceTracker.Config) -> String {
        var parts = [String(format: "hold %.2f s", c.speakerHold)]
        if c.silenceGap != 1.2 { parts.append(String(format: "silence gap %.2f s", c.silenceGap)) }
        if c.wordLead != 0.25 { parts.append(String(format: "word lead %.2f s", c.wordLead)) }
        if c.cutAtPause { parts.append(String(format: "cut at pause ≥ %.2f s within %.1f s", c.cutPause, c.cutPauseWindow)) }
        if let r = c.smoothABA { parts.append(String(format: "A-B-A ≤ %d words ≤ %.1f s, gaps ≤ %.1f s", r.maxWords, r.maxSeconds, r.maxGap)) }
        return parts.joined(separator: ", ")
    }
}
