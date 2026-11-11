import AVFoundation
import FluidAudio
import Foundation
import os

/// Live English speech-to-text on the Neural Engine via FluidAudio's cache-aware streaming models.
///
/// One instance per speaker. `feed` only enqueues (an `AsyncStream` yield, lock-free for the
/// caller); a single worker task owns the FluidAudio manager and the `UtteranceTracker`, so all
/// model calls and line bookkeeping run serially off the audio thread.
///
/// Default variant: see `defaultVariant` for the measurements behind the choice. Override without a
/// rebuild: `defaults write dev.hearsay.app engineVariant nemotron-1120ms` (any
/// `StreamingModelVariant` raw value except the offline Unified batch mode).
final class ParakeetEngine: TranscriptionEngine, @unchecked Sendable {
    /// Parakeet Unified 0.6B, 640 ms tier (0.56 s chunk + 0.08 s look-ahead).
    ///
    /// Measured on the M4 MacBook Air (release build, three macOS-TTS clips, 66 s, ~160 words;
    /// RTF = compute time / audio time for one stream; footprint = peak phys_footprint):
    ///
    ///   variant          word errors        RTF    footprint  download
    ///   eou-160ms        ~13, no punct      0.086   47 MB     214 MB
    ///   eou-320ms        ~6,  no punct      0.028   46 MB     214 MB
    ///   nemotron-560ms   2,   partial punct 0.050   91 MB     597 MB
    ///   nemotron-1120ms  2,   partial punct 0.057   91 MB     598 MB
    ///   unified-320ms    1,   punct + ITN   0.164   53 MB     ~590 MB
    ///   unified-640ms    2,   punct + ITN   0.045   53 MB     ~580 MB
    ///   unified-1120ms   0,   punct + ITN   0.044   54 MB     ~590 MB
    ///
    /// EOU is fast and small but lowercase, unpunctuated and noticeably less accurate. Unified gives
    /// transcript-ready text ("15%", "No? Great.") at Nemotron-level accuracy with ~40 MB less memory
    /// per stream. Its 320 ms tier re-encodes the window 3.5x as often (RTF 0.16 per stream, too much
    /// for two always-on streams); 640 ms costs the same as 1120 ms but shows words ~0.5 s sooner.
    /// Live (paced) on a 50 s clip: first partial 0.85 s after audio start, finals 1.1 s after the
    /// speaker stops (= the silence gap). Me + them together: 64–67 MB peak footprint, RTF 0.037.
    /// (All variants dropped the first word until `prime()` existed; numbers above are with it.)
    static let defaultVariant: StreamingModelVariant = .parakeetUnified640ms

    /// The variant from `UserDefaults["engineVariant"]`, falling back to `defaultVariant`.
    static func configuredVariant(_ defaults: UserDefaults = .standard) -> StreamingModelVariant {
        guard let raw = defaults.string(forKey: "engineVariant") else { return defaultVariant }
        guard let v = StreamingModelVariant(rawValue: raw), v != .parakeetUnifiedOffline15s else {
            Log.warn("engine: unknown or non-streaming engineVariant '\(raw)', using \(defaultVariant.rawValue)")
            return defaultVariant
        }
        return v
    }

    /// Output lag of each variant: chunk (+ right context for Unified). Feeds the silence rule.
    static func latency(of v: StreamingModelVariant) -> TimeInterval {
        if let c = v.eouChunkSize { return Double(c.durationMs) / 1000 }
        if let c = v.nemotronChunkSize { return Double(c.rawValue) / 1000 }
        if let c = v.unifiedConfig { return Double(c.latencyMs) / 1000 }
        return 2
    }

    let variant: StreamingModelVariant
    private let trackerConfig: UtteranceTracker.Config
    /// Partials are coalesced to at most one per this interval (UI repaint budget).
    private let partialInterval: Duration = .milliseconds(200)

    var identifier: String { variant.rawValue }
    var displayName: String { variant.displayName }
    /// Every `StreamingModelVariant` (EOU, Nemotron streaming, Unified) is an English-only checkpoint.
    var languages: [String] { ["en"] }

    private struct State: @unchecked Sendable {
        var manager: (any StreamingAsrManager)?
        var inbox: AsyncStream<AudioChunk>.Continuation?
        var worker: Task<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Samples fed but not yet consumed by the worker; used to warn when inference falls behind.
    private let backlog = OSAllocatedUnfairLock(initialState: 0)

    init(variant: StreamingModelVariant? = nil, tracker: UtteranceTracker.Config = .init()) {
        let v = variant ?? Self.configuredVariant()
        self.variant = v
        var cfg = tracker
        cfg.modelLatency = Self.latency(of: v)
        self.trackerConfig = cfg
    }

    func prepare(progress: @escaping @Sendable (ModelState) -> Void) async throws {
        if state.withLock({ $0.manager }) != nil { progress(.ready); return }
        do {
            try await ModelStore.shared.ensureDownloaded(variant, progress: progress)
            let m = try await ModelStore.shared.makeManager(variant)
            state.withLock { $0.manager = m }
            progress(.ready)
        } catch is CancellationError {
            throw CancellationError()   // paused or cancelled by the user; the session decides what to show
        } catch {
            Log.error("engine \(identifier): prepare failed: \(error.localizedDescription)")
            progress(.failed(error.localizedDescription))
            throw error
        }
    }

    func start(speaker: Speaker) async throws -> AsyncStream<EngineEvent> {
        try await start(speaker: speaker, stream: nil)
    }

    /// `stream` names this stream for `DiarizerRegistry` (a lane, or one app of the them lane);
    /// the registry hands back the same diarizer for the key within a session, so pause/resume
    /// and a per-app stream reopening keep their speaker slots.
    func start(speaker: Speaker, stream: String?) async throws -> AsyncStream<EngineEvent> {
        await stop()  // a second start without stop must not leave an orphaned worker
        guard let manager = state.withLock({ $0.manager }) else { throw EngineError.notPrepared }
        let key = stream ?? speaker.rawValue
        let diarizer = await DiarizerRegistry.shared.diarizer(for: speaker, stream: key)
        let (events, out) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .unbounded)
        let (inbox, input) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        backlog.withLock { $0 = 0 }
        let job = Job(manager: manager, speaker: speaker, engine: identifier, config: trackerConfig,
                      partialInterval: partialInterval, backlog: backlog, out: out,
                      stream: key, diarizer: diarizer)
        let worker = Task.detached(priority: .userInitiated) { await job.run(inbox) }
        state.withLock { $0.inbox = input; $0.worker = worker }
        Log.info("engine \(identifier): started for \(key)\(diarizer.map { " with \($0.kind.rawValue)" } ?? "")")
        return events
    }

    func feed(_ chunk: AudioChunk) async {
        guard let inbox = state.withLock({ $0.inbox }) else { return }
        backlog.withLock { $0 += chunk.samples.count }
        inbox.yield(chunk)
    }

    func stop() async {
        let (inbox, worker) = state.withLock { s -> (AsyncStream<AudioChunk>.Continuation?, Task<Void, Never>?) in
            defer { s.inbox = nil; s.worker = nil }
            return (s.inbox, s.worker)
        }
        inbox?.finish()
        await worker?.value
    }
}

/// One listening session: drains the inbox through the model and turns transcripts into events.
private struct Job: Sendable {
    let manager: any StreamingAsrManager
    let speaker: Speaker
    let engine: String
    let config: UtteranceTracker.Config
    let partialInterval: Duration
    let backlog: OSAllocatedUnfairLock<Int>
    let out: AsyncStream<EngineEvent>.Continuation
    /// Stream key for speaker ids, and the diarizer that tells this stream's speakers apart (nil: off).
    let stream: String
    let diarizer: SpeakerDiarizer?
    /// The diarizer keeps running this long after the last voiced chunk: its look-ahead (0.56 s
    /// for Sortformer) plus one of its 480 ms chunks, so the frames of the speech get decided.
    /// Beyond that silence is skipped: no inference while the lane is quiet.
    private static let diarizerHangover = Int(1.2 * AudioChunk.sampleRate)

    private static let format = AVAudioFormat(standardFormatWithSampleRate: AudioChunk.sampleRate, channels: 1)!

    func run(_ inbox: AsyncStream<AudioChunk>) async {
        var tracker = UtteranceTracker(config: config)
        let clock = ContinuousClock()
        var lastPartialAt = clock.now - partialInterval
        var lastPartialText = ""
        var behind = false
        var errors = 0
        var lastPartialSpeaker: String?
        var diarizeUntil = 0
        var diarizerErrors = 0
        var timingsMisaligned = false
        await prime()
        // Lane sample at which the model's clock (frames since its last reset) started, after the
        // priming silence: model time t ↔ lane sample origin + (t − prime) × rate.
        var modelOrigin = 0

        for await chunk in inbox where !chunk.samples.isEmpty {
            let queued = backlog.withLock { $0 -= chunk.samples.count; return $0 }
            let queuedSec = Double(queued) / AudioChunk.sampleRate
            if queuedSec > 8, !behind {
                behind = true
                out.yield(.warning("Transcription is running \(Int(queuedSec)) s behind the audio."))
                Log.warn("engine \(engine): backlog \(String(format: "%.1f", queuedSec)) s")
            } else if queuedSec < 2 { behind = false }

            let base = tracker.samplesFed
            let voiced = tracker.ingest(chunk)
            if let diarizer {
                if voiced { diarizeUntil = tracker.samplesFed + Self.diarizerHangover }
                if voiced || base < diarizeUntil {
                    do {
                        if let frames = try diarizer.feed(chunk.samples, laneSample: base) {
                            tracker.observe(frames)
                            if Self.trace, !frames.finalized.isEmpty {
                                let rate = AudioChunk.sampleRate
                                print(String(format: "  @%.2f runs: ", Double(tracker.samplesFed) / rate) + frames.finalized.map { String(format: "s%d[%.2f–%.2f]", $0.speaker, Double($0.start) / rate, Double($0.end) / rate) }.joined(separator: " "))
                            }
                        }
                    } catch {
                        diarizerErrors += 1
                        if diarizerErrors == 1 { Log.error("diarizer \(stream): \(error.localizedDescription)") }
                    }
                }
            }
            do {
                try await manager.appendAudio(Self.buffer(chunk.samples))
                try await manager.processBufferedAudio()
            } catch {
                errors += 1
                if errors == 1 || errors % 100 == 0 {
                    Log.error("engine \(engine): inference error #\(errors): \(error.localizedDescription)")
                    out.yield(.warning(EngineError.inference(error.localizedDescription).localizedDescription))
                }
                continue
            }
            tracker.update(transcript: await manager.getPartialTranscript())
            await Self.collectWordTimes(manager, into: &tracker, origin: modelOrigin, misaligned: &timingsMisaligned, stream: stream)

            var modelEnd = false
            if let eou = manager as? StreamingEouAsrManager { modelEnd = await eou.eouDetected }
            if let reason = tracker.finalReason(modelSignalledEnd: modelEnd) {
                // Silence-type reasons restart the model (nothing is lost, and its token buffer stays
                // bounded); mid-speech cuts keep it running and leave the remainder pending.
                let reset = !reason.isSplit
                if let line = tracker.commit(reason: reason, speaker: speaker, engine: engine, modelWillReset: reset,
                                             stream: diarizer == nil ? nil : stream) {
                    out.yield(.final(line))
                }
                if reset { try? await manager.reset(); await prime(); modelOrigin = tracker.samplesFed }
                lastPartialText = ""
                continue
            }

            let pending = tracker.pending
            let who = diarizer == nil ? nil : tracker.currentSpeaker.map { SpeakerID.make(stream: stream, slot: $0) }
            if pending != lastPartialText || who != lastPartialSpeaker, clock.now - lastPartialAt >= partialInterval {
                out.yield(.partial(text: pending, speaker: speaker, app: tracker.currentApp, speakerID: who))
                lastPartialText = pending
                lastPartialSpeaker = who
                lastPartialAt = clock.now
            }
        }

        // Inbox finished (stop): flush the model's buffered audio and commit whatever is left.
        do {
            // The models emit a word only once they have seen audio past it (chunk + look-ahead);
            // without trailing silence the last word of a session gets clipped ("privacy cop").
            let pad = Int((config.modelLatency + 0.5) * AudioChunk.sampleRate)
            try await manager.appendAudio(Self.buffer([Float](repeating: 0, count: pad)))
            try await manager.processBufferedAudio()
            // The same for the diarizer, so its look-ahead frames get decided too. It is not
            // finalised: that would end its session, and its slots must survive a pause.
            if let diarizer, tracker.samplesFed < diarizeUntil,
               let frames = try? diarizer.feed([Float](repeating: 0, count: pad), laneSample: tracker.samplesFed) {
                tracker.observe(frames)
            }
            tracker.update(transcript: try await manager.finish())
            await Self.collectWordTimes(manager, into: &tracker, origin: modelOrigin, misaligned: &timingsMisaligned, stream: stream)
            if let line = tracker.commit(reason: .flush, speaker: speaker, engine: engine, modelWillReset: true,
                                         stream: diarizer == nil ? nil : stream) {
                out.yield(.final(line))
            }
        } catch {
            Log.error("engine \(engine): flush failed: \(error.localizedDescription)")
        }
        try? await manager.reset()
        out.finish()
        let revised = tracker.realignments > 0 ? ", \(tracker.realignments) committed-text revisions realigned" : ""
        Log.info("engine \(engine): stopped (\(speaker.rawValue))\(revised)")
    }

    /// Hands the model's per-token timings (Unified only) to the tracker, in lane samples. They
    /// place each word for speaker attribution and line ends; the RNN-T records the encoder
    /// frame at which it emitted each token, so they are exact to a frame (80 ms).
    private static func collectWordTimes(_ manager: any StreamingAsrManager, into tracker: inout UtteranceTracker,
                                         origin: Int, misaligned: inout Bool, stream: String) async {
        guard let unified = manager as? StreamingUnifiedAsrManager else { return }
        let words = await unified.consumeTokenTimings()
        guard !words.isEmpty else { return }
        let rate = AudioChunk.sampleRate
        tracker.addPieceTimes(words.map { w in
            (w.token, origin + Int((w.startTime - primeSeconds) * rate), origin + Int((w.endTime - primeSeconds) * rate))
        })
        if trace {
            let fed = Double(tracker.samplesFed) / rate
            print(String(format: "  @%.2f pieces: ", fed) + words.map { String(format: "'%@'[%.2f–%.2f]", $0.token, Double(origin) / rate + $0.startTime - primeSeconds, Double(origin) / rate + $0.endTime - primeSeconds) }.joined(separator: " "))
        }
        if !tracker.pieceTimesAligned, !misaligned {
            misaligned = true
            Log.warn("engine \(stream): word timings do not line up with the transcript; using text ages instead")
        }
    }

    private static let primeSeconds = 0.3
    /// `HEARSAY_TRACE=1 hearsay --transcribe …`: prints word timings and diarizer runs (CLI only).
    static let trace = ProcessInfo.processInfo.environment["HEARSAY_TRACE"] != nil

    /// Feeds a little silence into a fresh (or just reset) model. Every variant dropped the first
    /// word ("The quarterly…" → "Quarterly…") when speech started on the very first sample; a
    /// short lead-in gives the encoder context. Not seen by the tracker, so timing is unaffected.
    private func prime() async {
        try? await manager.appendAudio(Self.buffer([Float](repeating: 0, count: Int(Self.primeSeconds * AudioChunk.sampleRate))))
    }

    /// Wraps samples in the 16 kHz mono Float32 buffer FluidAudio's `appendAudio` expects
    /// (its converter passes this format through without resampling).
    static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }
}
