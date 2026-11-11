import Foundation

/// The "them" engine when system audio arrives per app (`PerAppAudioTap`): one model stream per
/// app, so two apps playing at once are transcribed separately instead of as one blended line.
///
/// Chunks are routed by `sourceApps.first`. A stream is opened for an app on its first voiced
/// chunk (silence from an idle app never costs a model), fed everything after that, and closed
/// (flushed: its trailing words become a final line) after `idleTimeout` without audio, or on
/// `stop()`. Each stream is an ordinary engine from `make` (a `ParakeetEngine`, ~50 MB, ~1% CPU
/// while fed); at most `maxStreams` at once. The first engine is prepared at launch like before
/// and kept warm between sessions, so the common single-app case costs nothing extra.
///
/// Events from all streams are merged into one stream in arrival order. Lines and partials carry
/// their app through the tracker's app votes, which in a per-app stream are unanimous.
actor PerAppEngine: TranscriptionEngine {
    nonisolated let identifier: String
    nonisolated let displayName: String
    nonisolated let languages: [String]

    static let maxStreams = 4
    static let idleTimeout: Duration = .seconds(20)
    /// RMS below which a chunk is silence for the purpose of OPENING a stream (−48 dBFS).
    static let voiceFloor: Float = 0.004

    private struct Stream {
        let engine: TranscriptionEngine
        var forwarder: Task<Void, Never>
        var lastChunk: ContinuousClock.Instant
    }

    private let make: () -> TranscriptionEngine
    /// A prepared engine waiting for an app (the one prepared at launch, or the last one closed).
    private var warm: TranscriptionEngine?
    private var streams: [String: Stream] = [:]
    private var out: AsyncStream<EngineEvent>.Continuation?
    private var speaker: Speaker = .them
    private var housekeeper: Task<Void, Never>?
    private var warnedLimit = false

    init(make: @escaping () -> TranscriptionEngine) {
        let first = make()
        identifier = first.identifier
        displayName = first.displayName
        languages = first.languages
        self.make = make
        warm = first
    }

    func prepare(progress: @escaping @Sendable (ModelState) -> Void) async throws {
        if warm == nil { warm = make() }
        try await warm!.prepare(progress: progress)
    }

    func start(speaker: Speaker) async throws -> AsyncStream<EngineEvent> {
        await stop()
        self.speaker = speaker
        let (events, cont) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .unbounded)
        out = cont
        housekeeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.closeIdle()
            }
        }
        Log.info("engine per-app: started for \(speaker.rawValue)")
        return events
    }

    func feed(_ chunk: AudioChunk) async {
        guard out != nil else { return }
        let app = chunk.sourceApps.first ?? ""
        if streams[app] == nil {
            guard Self.rms(chunk.samples) >= Self.voiceFloor else { return }
            guard streams.count < Self.maxStreams else {
                if !warnedLimit { Log.warn("engine per-app: \(Self.maxStreams) streams open; not transcribing \(app)"); warnedLimit = true }
                return
            }
            guard let s = await open(app) else { return }
            streams[app] = s
        }
        streams[app]!.lastChunk = .now
        await streams[app]!.engine.feed(chunk)
    }

    func stop() async {
        housekeeper?.cancel(); housekeeper = nil
        let open = streams
        streams = [:]
        await withTaskGroup(of: Void.self) { group in
            for (_, s) in open { group.addTask { await s.engine.stop(); await s.forwarder.value } }
        }
        if warm == nil, let s = open.values.first { warm = s.engine }
        if !open.isEmpty { Log.info("engine per-app: closed \(open.count) stream\(open.count == 1 ? "" : "s")") }
        out?.finish(); out = nil
        warnedLimit = false
    }

    // MARK: Streams

    private func open(_ app: String) async -> Stream? {
        guard let out else { return nil }
        let engine: TranscriptionEngine
        if let w = warm {
            engine = w; warm = nil
        } else {
            engine = make()
            do { try await engine.prepare { _ in } } catch {
                Log.error("engine per-app: could not load a model for \(app): \(error.localizedDescription)")
                return nil
            }
        }
        do {
            let events = try await engine.start(speaker: speaker, stream: app.isEmpty ? nil : SpeakerID.stream(.them, app: app))
            let forwarder = Task.detached(priority: .userInitiated) { for await e in events { out.yield(e) } }
            Log.info("engine per-app: stream opened for \(app.isEmpty ? "unknown app" : app) (\(streams.count + 1) open)")
            return Stream(engine: engine, forwarder: forwarder, lastChunk: .now)
        } catch {
            Log.error("engine per-app: start for \(app) failed: \(error.localizedDescription)")
            warm = engine
            return nil
        }
    }

    private func close(_ app: String) async {
        guard let s = streams.removeValue(forKey: app) else { return }
        await s.engine.stop()
        await s.forwarder.value
        if warm == nil { warm = s.engine }
        Log.info("engine per-app: stream closed for \(app.isEmpty ? "unknown app" : app) (\(streams.count) open)")
    }

    private func closeIdle() async {
        let now = ContinuousClock.now
        for (app, s) in streams where now - s.lastChunk > Self.idleTimeout { await close(app) }
    }

    private static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for x in s { sum += x * x }
        return (sum / Float(s.count)).squareRoot()
    }
}
