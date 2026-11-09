import AVFoundation
import CoreAudio
import Foundation

/// "me": the default input device via AVAudioEngine, with Apple's voice-processing unit on.
///
/// Voice processing gives acoustic echo cancellation (the far side playing through built-in
/// speakers should not leak back in as "me") and makes the Control Center mic modes
/// (Standard / Voice Isolation / Wide Spectrum) apply to us.
///
/// All mutable state lives on `queue`; the tap block only hops onto it.
final class MicCapture: AudioSource {
    let speaker: Speaker = .me
    private(set) var displayName: String = "Microphone"

    private let queue = DispatchQueue(label: "hearsay.mic", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var deviceID = CA.unknown
    private var resampler: Resampler16k?
    private var assembler = ChunkAssembler(speaker: .me)
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var configObserver: NSObjectProtocol?
    private var pendingChange: DispatchWorkItem?
    private var generation = 0   // bumps on every tap install so buffers from a dead tap are dropped

    init() { displayName = CA.name(CA.defaultInputDevice) ?? "Microphone" }

    func start() throws -> AsyncStream<AudioChunk> {
        switch Permissions.microphone {
        case .denied: throw AudioSourceError.permissionDenied(.me)
        case .notDetermined:
            // start() is synchronous by contract, so block on the prompt. Call from a background
            // task, or call Permissions.requestMicrophone() first, to keep the main thread free.
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { granted = $0; sem.signal() }
            sem.wait()
            if !granted { throw AudioSourceError.permissionDenied(.me) }
        default: break
        }

        stop()
        let (stream, cont) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        try queue.sync {
            continuation = cont
            assembler = ChunkAssembler(speaker: .me)
            do { try buildEngine() } catch { continuation = nil; throw error }
        }
        cont.onTermination = { [weak self] _ in self?.stop() }
        return stream
    }

    func stop() {
        queue.sync {
            guard continuation != nil || engine != nil else { return }
            tearDownEngine()
            if let tail = resampler?.flush(), !tail.isEmpty {
                for c in assembler.append(tail, startTime: nil) { continuation?.yield(c) }
            }
            if let last = assembler.flush() { continuation?.yield(last) }
            resampler = nil
            let c = continuation
            continuation = nil
            c?.onTermination = nil   // finish() would call it synchronously, re-entering this queue
            c?.finish()
            Log.info("mic: stopped")
        }
    }

    // MARK: Engine lifecycle (on `queue`)

    private func buildEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Must happen BEFORE reading the format / installing the tap: enabling voice processing
        // swaps the underlying AU (VoiceProcessingIO) and changes the input format.
        do {
            try input.setVoiceProcessingEnabled(true)
            // VPIO ducks *all other audio* by default (Zoom's own playback would drop ~15 dB
            // while we record). Ask for the least ducking we can get.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        } catch {
            Log.warn("mic: voice processing unavailable (\(error.localizedDescription)); capturing raw input without echo cancellation")
        }

        // With voice processing on, a MacBook Air reports 5 or 7 channels at 48 kHz (it changes
        // while VPIO settles), all carrying the same processed signal, so Resampler16k's channel
        // average is lossless here.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioSourceError.deviceUnavailable("no input device (format \(format))")
        }
        installTap(on: input)
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw AudioSourceError.deviceUnavailable("could not start microphone: \(error.localizedDescription)")
        }
        self.engine = engine
        deviceID = CA.defaultInputDevice
        displayName = CA.name(deviceID) ?? "Microphone"

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.scheduleConfigurationChange() }
        }
        Log.info("mic: started on \"\(displayName)\" \(Int(format.sampleRate)) Hz × \(format.channelCount) ch, voice processing \(input.isVoiceProcessingEnabled ? "on" : "off")")
    }

    /// `format: nil` = whatever the node produces right now. A fixed format raises an ObjC
    /// exception once VPIO changes its channel count; process() adapts per buffer instead.
    private func installTap(on input: AVAudioInputNode) {
        generation += 1
        let gen = generation
        let rate = max(input.outputFormat(forBus: 0).sampleRate, AudioChunk.sampleRate)
        // ~100 ms of native frames; the engine treats this as a hint.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(rate / 10), format: nil) { [weak self] buffer, when in
            guard let self else { return }
            let host: UInt64? = when.isHostTimeValid ? when.hostTime : nil
            self.queue.async { self.process(buffer, hostTime: host, generation: gen) }
        }
    }

    private func tearDownEngine() {
        pendingChange?.cancel(); pendingChange = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Configuration changes arrive in bursts (a device switch posts several while VPIO
    /// renegotiates), and reacting to each one feeds a rebuild → notification → rebuild loop
    /// (observed: 6 rebuilds in 3 s). Coalesce them and act once it has been quiet for 300 ms.
    private func scheduleConfigurationChange() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.handleConfigurationChange() }
        pendingChange = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Fires when the default input changes, a device is unplugged, or the format changes; the
    /// engine has usually stopped itself. Same device → restart in place (building a new VPIO
    /// engine posts yet another change). Different device → a fresh engine.
    private func handleConfigurationChange() {
        pendingChange = nil
        guard continuation != nil, let engine else { return }
        let newDevice = CA.defaultInputDevice
        if newDevice == deviceID {
            if engine.isRunning { return }
            engine.inputNode.removeTap(onBus: 0)
            installTap(on: engine.inputNode)
            do {
                try engine.start()
                Log.info("mic: engine restarted after configuration change")
                return
            } catch {
                Log.warn("mic: restart failed (\(error.localizedDescription)); rebuilding")
            }
        }
        Log.info("mic: input changed to \"\(CA.name(newDevice) ?? "none")\"; rebuilding engine")
        tearDownEngine()
        do {
            try buildEngine()
        } catch {
            // Device vanished with nothing to replace it: retry instead of ending the stream, so
            // plugging a mic back in resumes the transcript.
            Log.warn("mic: rebuild failed (\(error.localizedDescription)); retrying every 1 s")
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.continuation != nil, self.engine == nil else { return }
            do { try self.buildEngine() } catch { self.scheduleRetry() }
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?, generation gen: Int) {
        guard gen == generation, let continuation else { return }
        if resampler?.inputFormat != buffer.format {
            if let tail = resampler?.flush(), !tail.isEmpty {
                for c in assembler.append(tail, startTime: nil) { continuation.yield(c) }
            }
            resampler = Resampler16k(inputFormat: buffer.format)
            if resampler == nil { Log.warn("mic: unsupported input format \(buffer.format)"); return }
        }
        guard let resampler else { return }
        let samples = resampler.convert(buffer)
        let start = hostTime.map(CA.date(fromHostTime:))
        for chunk in assembler.append(samples, startTime: start) { continuation.yield(chunk) }
    }
}
