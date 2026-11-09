import Foundation

/// Owns the live session. Per enabled speaker a "lane" runs:
///
///     Wiring.makeSource(speaker).start()  ──chunks──▶  engine.feed      (detached task, audio rate)
///     engine.start(speaker:) events       ──────────▶  handle(_:)       (main actor)
///
/// `.partial` → AppModel only; `.final` → TranscriptStore (disk) + AppModel; `.warning` → log +
/// status line. The feed task also measures each chunk's level for the recording bar's waveform.
///
/// Pause stops every lane exactly like Stop (sources off, engines flush their trailing text as
/// finals) but keeps the store and the start time; Resume starts the lanes again into the same
/// store. So while paused no audio is captured at all, which is the point of pausing. Engines are created and prepared once at launch and reused for every session;
/// sources are created per start and dropped after stop.
///
/// Main actor; nothing here blocks it: preparation, starts and stops are async tasks.
@MainActor
final class SessionController {
    let model: AppModel
    /// Called after any state change the menu bar should reflect.
    var onChange: () -> Void = {}

    private var engines: [Speaker: TranscriptionEngine] = [:]
    private var lanes: [Speaker: Lane] = [:]
    private var prepareTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    /// Pause / resume lane work in flight; stop and the opposite transition wait for it.
    private var pauseTask: Task<Void, Never>?
    /// Start was requested before the model was ready; begin as soon as it is.
    private var startWhenReady = false
    /// Every engine finished `prepare` (the model state can read .ready while the second is still loading).
    private var enginesReady = false
    private var warningToken = 0
    /// Current session's transcript, or the last one after stop (for Open / Copy).
    private(set) var store: TranscriptStore?

    private final class Lane {
        let source: AudioSource
        var feed: Task<Void, Never>?
        var events: Task<Void, Never>?
        var stopping = false
        init(source: AudioSource) { self.source = source }
    }

    init(model: AppModel) { self.model = model }

    // MARK: Source preferences

    static func isEnabled(_ s: Speaker) -> Bool { UserDefaults.standard.object(forKey: "source.\(s.rawValue)") as? Bool ?? true }

    /// Persists the choice and, mid-session, starts or stops just that speaker so the transcript
    /// file carries on.
    func setEnabled(_ s: Speaker, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "source.\(s.rawValue)")
        Log.info("source \(s.rawValue) \(on ? "enabled" : "disabled")")
        // While paused only the preference changes; resume() starts whatever is enabled then.
        guard model.phase == .listening else { onChange(); return }
        Task {
            if on { await startLane(s) } else { await stopLane(s) }
            if lanes.isEmpty { stop() }
            onChange()
        }
    }

    // MARK: Engine preparation

    /// Creates both engines and prepares them (model download / load). Safe to call again after a
    /// failure (Start listening retries).
    func prepareEngines() {
        guard prepareTask == nil, !enginesReady else { return }
        if engines.isEmpty {
            for s in Speaker.allCases { engines[s] = Wiring.makeEngine() }
            model.engineID = engines[.me]?.identifier ?? ""
        }
        let engines = Speaker.allCases.compactMap { self.engines[$0] }
        let report: @Sendable (ModelState) -> Void = { [weak self] state in
            Task { @MainActor in self?.applyProgress(state) }
        }
        prepareTask = Task {
            do {
                for engine in engines { try await engine.prepare(progress: report) }
                Log.info("engines ready: \(model.engineID)")
                model.modelState = .ready; enginesReady = true
            } catch {
                Log.error("engine prepare failed: \(error)")
                model.modelState = .failed(error.localizedDescription)
                startWhenReady = false
                if model.phase == .starting { model.phase = .idle }
            }
            prepareTask = nil
            onChange()
            if startWhenReady { startWhenReady = false; model.phase = .idle; start() }
        }
    }

    private func applyProgress(_ state: ModelState) {
        // Once ready, ignore late progress callbacks (they hop here asynchronously).
        guard model.modelState != .ready, model.modelState != state else { return }
        model.modelState = state
        onChange()
    }

    // MARK: Start / stop

    /// ⌃⌥H: stops any session (listening OR paused), otherwise starts one.
    func toggle() { if model.isActive { stop() } else { start() } }

    /// ⌃⌥P: pause while listening, resume while paused, nothing otherwise.
    func togglePause() {
        switch model.phase {
        case .listening: pause()
        case .paused: resume()
        default: break
        }
    }

    func start() {
        guard model.phase == .idle else { return }
        if !enginesReady {
            Log.info("start requested before the model is ready; will start when it is")
            startWhenReady = true
            model.phase = .starting
            prepareEngines()
            onChange()
            return
        }
        let speakers = Speaker.allCases.filter(Self.isEnabled)
        guard !speakers.isEmpty else { showWarning("Both sources are off (Sources menu)."); return }
        let previous = store
        let now = Date()
        store = TranscriptStore(startedAt: now, engine: model.engineID)
        model.phase = .starting
        model.startedAt = now
        model.lines = []
        model.partials = [:]
        model.pausedTotal = 0
        model.pausedAt = nil
        model.permissionDenied = []
        model.audio.reset()
        model.audio.run()
        onChange()
        Log.info("session: starting \(speakers.map(\.rawValue))")
        startTask = Task {
            for s in speakers { await startLane(s) }
            startTask = nil
            if lanes.isEmpty {
                Log.warn("session: no source could start")
                store = previous
                model.phase = .idle
                model.audio.reset()
            } else if model.phase == .starting {
                model.phase = .listening
            }
            onChange()
        }
    }

    /// Idempotent. Stops sources, flushes engines (their trailing finals still land in the
    /// transcript), then finalises the file. The returned task completes when that is done.
    @discardableResult
    func stop() -> Task<Void, Never>? {
        if startWhenReady { startWhenReady = false; model.phase = .idle; onChange(); return nil }
        guard model.isActive else { return stopTask }
        model.phase = .stopping
        onChange()
        Log.info("session: stopping")
        let pending = [startTask, pauseTask]
        stopTask = Task {
            for t in pending { await t?.value }
            for s in Array(lanes.keys) { await stopLane(s) }
            store?.finish()               // closes a pause still open (stop while paused)
            model.partials = [:]
            model.pausedAt = nil
            model.audio.reset()
            model.phase = .idle
            stopTask = nil
            onChange()
            Log.info("session: stopped")
        }
        return stopTask
    }

    /// Stops every lane (trailing finals still land in the store) but keeps the session: same
    /// store, same start time. The pause is recorded in the store for the marker and header.
    func pause() {
        guard model.phase == .listening else { return }
        let now = Date()
        store?.beginPause(at: now)
        model.pausedAt = now
        model.phase = .paused
        model.audio.freeze()
        onChange()
        Log.info("session: pausing")
        let previous = pauseTask
        pauseTask = Task {
            await previous?.value
            for s in Array(lanes.keys) { await stopLane(s) }
            model.partials = [:]
            pauseTask = nil
            Log.info("session: paused")
        }
    }

    /// Restarts the enabled lanes into the same store.
    func resume() {
        guard model.phase == .paused else { return }
        let now = Date()
        store?.endPause(at: now)
        if let p = model.pausedAt { model.pausedTotal += now.timeIntervalSince(p) }
        model.pausedAt = nil
        model.phase = .starting
        model.audio.run()
        onChange()
        Log.info("session: resuming")
        let previous = pauseTask
        pauseTask = Task {
            await previous?.value
            for s in Speaker.allCases where Self.isEnabled(s) { await startLane(s) }
            pauseTask = nil
            if lanes.isEmpty {
                // Nothing could start (both sources off, permission revoked): end the session
                // rather than pretend to listen.
                Log.warn("session: resume found no source to start; stopping")
                stop()
            } else if model.phase == .starting {
                model.phase = .listening
                Log.info("session: resumed")
            }
            onChange()
        }
    }

    /// Quit path: stop and finalise, but never hold the quit longer than `timeout` (a wedged engine
    /// must not keep the app alive); the transcript is finalised either way.
    func stopForQuit(timeout: TimeInterval, completion: @escaping () -> Void) {
        var done = false
        let finish = { [weak self] in
            guard !done else { return }
            done = true
            if let store = self?.store, store.endedAt == nil { store.finish() }
            completion()
        }
        guard let task = stop() else { finish(); return }
        Task { await task.value; finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !done { Log.warn("session: stop timed out after \(timeout) s; finalising anyway") }
            finish()
        }
    }

    // MARK: Lanes

    private func startLane(_ s: Speaker) async {
        guard lanes[s] == nil, let engine = engines[s] else { return }
        let source = Wiring.makeSource(s)
        let lane = Lane(source: source)
        lanes[s] = lane   // reserve the slot so a concurrent toggle doesn't double-start
        let events: AsyncStream<EngineEvent>
        do {
            events = try await engine.start(speaker: s)
        } catch {
            Log.error("engine start (\(s.rawValue)) failed: \(error)")
            showWarning(error.localizedDescription)
            lanes[s] = nil
            return
        }
        // Stopped (source toggled off) while the engine was starting: back out.
        guard lanes[s] === lane, !lane.stopping else { await engine.stop(); return }
        let chunks: AsyncStream<AudioChunk>
        do {
            chunks = try source.start()
        } catch {
            if case AudioSourceError.permissionDenied = error { model.permissionDenied.insert(s) }
            Log.error("source \(s.rawValue) (\(source.displayName)) failed to start: \(error)")
            showWarning(error.localizedDescription)
            await engine.stop()
            lanes[s] = nil
            return
        }
        model.permissionDenied.remove(s)
        Log.info("lane \(s.rawValue): \(source.displayName) → \(engine.identifier)")
        lane.events = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        let meter = model.audio.meter
        lane.feed = Task.detached(priority: .userInitiated) { [weak self] in
            for await chunk in chunks {
                meter.report(s, samples: chunk.samples)
                await engine.feed(chunk)
            }
            await self?.sourceEnded(s, lane: lane)
        }
    }

    private func stopLane(_ s: Speaker) async {
        guard let lane = lanes[s], !lane.stopping else { return }
        lane.stopping = true
        lane.source.stop()
        await lane.feed?.value            // every captured chunk has been fed
        await engines[s]?.stop()          // flush: trailing final, then the event stream ends
        await lane.events?.value          // …and every final has been stored
        lanes[s] = nil
        model.partials[s] = nil
        Log.info("lane \(s.rawValue): stopped")
    }

    /// A source's stream ended on its own (device unplugged, tap destroyed).
    private func sourceEnded(_ s: Speaker, lane: Lane) {
        guard !lane.stopping, lanes[s] === lane else { return }
        Log.warn("source \(s.rawValue) ended unexpectedly")
        showWarning(s == .me ? "Microphone stopped." : "System audio stopped.")
        Task { await stopLane(s); if lanes.isEmpty { stop() }; onChange() }
    }

    // MARK: Events

    private func handle(_ event: EngineEvent) {
        switch event {
        case .partial(let text, let speaker):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            model.partials[speaker] = t.isEmpty ? nil : t
        case .final(let line):
            guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                model.partials[line.speaker] = nil; return
            }
            store?.insert(line)
            model.insert(line)
        case .warning(let message):
            Log.warn("engine: \(message)")
            showWarning(message)
        }
    }

    func showWarning(_ message: String) {
        model.warning = message
        warningToken += 1
        let token = warningToken
        onChange()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.warningToken == token else { return }
            self.model.warning = nil
            self.onChange()
        }
    }
}
