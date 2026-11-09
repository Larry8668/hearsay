import Foundation

/// Owns the live session. Per enabled speaker a "lane" runs:
///
///     Wiring.makeSource(speaker).start()  ──chunks──▶  engine.feed      (detached task, audio rate)
///     engine.start(speaker:) events       ──────────▶  handle(_:)       (main actor)
///
/// `.partial` → AppModel only; `.final` → TranscriptStore (disk) + AppModel; `.warning` → log +
/// status line (see SessionController+Events.swift, which also runs the echo filter). The feed
/// task also measures each chunk's level for the recording bar's waveform and the echo filter.
///
/// Pause does NOT touch the audio devices: (re)building the mic's voice-processing unit or the
/// system tap reconfigures the output device, which makes other apps' audio stutter (see
/// docs/PERFORMANCE.md, "Audio glitches"). Instead each lane's gate closes: chunks are discarded,
/// the engines flush (trailing text becomes final lines) and the levels freeze. Resume restarts
/// the engines (fresh utterance state, so audio from before the pause is never stitched to new
/// speech) and reopens the gates. Start / stop do build and tear down the sources, both at once.
/// Engines are created and prepared once at launch and reused for every session; sources are
/// created per start and dropped after stop.
///
/// Main actor; nothing here blocks it: preparation, starts and stops are async tasks.
@MainActor
final class SessionController {
    let model: AppModel
    /// Called after any state change the menu bar should reflect.
    var onChange: () -> Void = {}

    var engines: [Speaker: TranscriptionEngine] = [:]
    /// Running lanes (see SessionController+Lanes.swift).
    var lanes: [Speaker: Lane] = [:]
    private var prepareTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    /// Pause / resume lane work in flight; stop and the opposite transition wait for it.
    private var pauseTask: Task<Void, Never>?
    /// Start was requested before the model was ready; begin as soon as it is.
    private var startWhenReady = false
    /// Drops mic lines that are just the speakers heard by the mic (see EchoFilter).
    var echo = EchoFilter()
    /// Per-lane chunk levels of the last minute, for the echo filter's level tie-break.
    let levelHistory = LevelHistory()
    /// Every engine finished `prepare` (the model state can read .ready while the second is still loading).
    private var enginesReady = false
    var warningToken = 0
    /// Current session's transcript, or the last one after stop (for Open / Copy).
    private(set) var store: TranscriptStore?

    init(model: AppModel) {
        self.model = model
        // Dev aid (like HEARSAY_AUTOSTART): with HEARSAY_AUTOMATION=1, end-to-end tests drive the
        // session by posting the distributed notification "dev.hearsay.control" with object
        // "toggle" (⌃⌥H) or "pause" (⌃⌥P); synthesized key events don't reach Carbon hotkeys.
        guard ProcessInfo.processInfo.environment["HEARSAY_AUTOMATION"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.hearsay.control"), object: nil, queue: .main
        ) { [weak self] note in
            let what = note.object as? String
            Log.info("automation: \(what ?? "?")")
            MainActor.assumeIsolated { if what == "toggle" { self?.toggle() } else if what == "pause" { self?.togglePause() } }
        }
    }

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
            for s in Speaker.allCases { engines[s] = Wiring.makeEngine(for: s) }
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
        echo = EchoFilter()
        levelHistory.clear()
        startTask = Task {
            await startLanes(speakers)
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

    /// Keeps the session (same store, same start time) and the audio devices running; every
    /// lane stops feeding its engine and the engines flush, so trailing finals still land in the
    /// store. The pause is recorded in the store for the marker and header.
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
            for s in Array(lanes.keys) { await pauseLane(s) }
            model.partials = [:]
            echo.resetMe()
            pauseTask = nil
            Log.info("session: paused")
        }
    }

    /// Reopens the lanes into the same store with fresh engine state. Sources enabled or disabled
    /// while paused are started / stopped now.
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
            for s in Speaker.allCases where !Self.isEnabled(s) { await stopLane(s) }
            for s in Array(lanes.keys) { await resumeLane(s) }
            await startLanes(Speaker.allCases.filter { Self.isEnabled($0) && lanes[$0] == nil })
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
}
