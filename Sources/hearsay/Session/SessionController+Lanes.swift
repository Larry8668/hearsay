import Foundation
import os

/// Lane lifecycle: start (source + engine), pause / resume (engine only, the source keeps
/// running), stop. Main actor, like the rest of SessionController.
extension SessionController {
    final class Lane {
        let source: AudioSource
        /// Open = chunks go to the engine; closed while paused (chunks are dropped).
        let gate = OSAllocatedUnfairLock(initialState: false)
        var feed: Task<Void, Never>?
        var events: Task<Void, Never>?
        var stopping = false
        init(source: AudioSource) { self.source = source }
    }

    /// Starts several lanes at once, so the sources' device setup (voice processing, process tap)
    /// overlaps instead of running back to back.
    func startLanes(_ speakers: [Speaker]) async {
        await withTaskGroup(of: Void.self) { group in
            for s in speakers { group.addTask { await self.startLane(s) } }
        }
    }

    func startLane(_ s: Speaker) async {
        guard lanes[s] == nil, let engine = engines[s] else { return }
        let source = Wiring.makeSource(s)
        let lane = Lane(source: source)
        lanes[s] = lane   // reserve the slot so a concurrent toggle doesn't double-start
        let events: AsyncStream<EngineEvent>
        do {
            events = try await engine.start(speaker: s)
        } catch {
            Log.error(.engine, "engine start (\(s.rawValue)) failed: \(error)")
            showWarning(error.localizedDescription)
            lanes[s] = nil
            return
        }
        // Stopped (source toggled off) while the engine was starting: back out.
        guard lanes[s] === lane, !lane.stopping else { await engine.stop(); return }
        let chunks: AsyncStream<AudioChunk>
        do {
            // Off the main actor: building the voice-processing unit blocks for a while.
            let box = SourceBox(source: source)
            chunks = try await Task.detached(priority: .userInitiated) { try box.source.start() }.value
        } catch {
            if case AudioSourceError.permissionDenied = error { model.permissionDenied.insert(s) }
            Log.error(.session, "source \(s.rawValue) (\(source.displayName)) failed to start: \(error)")
            showWarning(error.localizedDescription)
            await engine.stop()
            lanes[s] = nil
            return
        }
        // Stopped while the source was starting: stopLane found no feed task and has already
        // stopped the engine; just release the device.
        guard lanes[s] === lane, !lane.stopping else { source.stop(); return }
        model.permissionDenied.remove(s)
        Log.info(.session, "lane \(s.rawValue): \(source.displayName) → \(engine.identifier)")
        // The enrolled voice took a slot in this lane's diarizer: that speaker is "me".
        for (_, id) in await DiarizerRegistry.shared.enrolledIDs() where !model.speakers.enrolled.contains(id) {
            markEnrolled(speaker: id)
        }
        let meter = model.audio.meter, history = levelHistory, gate = lane.gate
        if model.phase == .paused {
            await engine.stop()   // started while pausing (a source toggled on): resume() opens it
        } else {
            lane.events = listen(events)
            gate.withLock { $0 = true }
        }
        lane.feed = Task.detached(priority: .userInitiated) { [weak self] in
            for await chunk in chunks where gate.withLock({ $0 }) {
                let rms = meter.report(s, samples: chunk.samples)
                history.record(s, rms: rms, start: chunk.startTime, end: chunk.endTime)
                await engine.feed(chunk)
            }
            await self?.sourceEnded(s, lane: lane)
        }
    }

    private func listen(_ events: AsyncStream<EngineEvent>) -> Task<Void, Never> {
        Task { [weak self] in for await event in events { self?.handle(event) } }
    }

    /// Pauses one lane: drop its chunks, flush its engine (trailing text becomes final lines).
    func pauseLane(_ s: Speaker) async {
        guard let lane = lanes[s], !lane.stopping, lane.events != nil else { return }
        lane.gate.withLock { $0 = false }
        await engines[s]?.stop()
        await lane.events?.value
        lane.events = nil
        model.clearPartials(s)
        Log.info(.session, "lane \(s.rawValue): paused (source keeps running)")
    }

    /// Resumes one lane: a fresh engine session, then chunks flow again.
    func resumeLane(_ s: Speaker) async {
        guard let lane = lanes[s], !lane.stopping, lane.events == nil, let engine = engines[s] else { return }
        do {
            lane.events = listen(try await engine.start(speaker: s))
        } catch {
            Log.error(.engine, "engine restart (\(s.rawValue)) failed: \(error)")
            showWarning(error.localizedDescription)
            await stopLane(s)
            return
        }
        lane.gate.withLock { $0 = true }
        Log.info(.session, "lane \(s.rawValue): resumed")
    }

    func stopLane(_ s: Speaker) async {
        guard let lane = lanes[s], !lane.stopping else { return }
        lane.stopping = true
        lane.source.stop()
        await lane.feed?.value            // every captured chunk has been fed
        await engines[s]?.stop()          // flush: trailing final, then the event stream ends
        await lane.events?.value          // …and every final has been stored
        lanes[s] = nil
        model.clearPartials(s)
        Log.info(.session, "lane \(s.rawValue): stopped")
    }

    /// A source's stream ended on its own (device unplugged, tap destroyed).
    private func sourceEnded(_ s: Speaker, lane: Lane) {
        guard !lane.stopping, lanes[s] === lane else { return }
        Log.warn(.session, "source \(s.rawValue) ended unexpectedly")
        showWarning(s == .me ? "Microphone stopped." : "System audio stopped.")
        Task { await stopLane(s); if lanes.isEmpty { stop() }; onChange() }
    }
}


/// Hands a source to the detached task that starts it (a source is used by one task at a time).
private struct SourceBox: @unchecked Sendable { let source: AudioSource }
