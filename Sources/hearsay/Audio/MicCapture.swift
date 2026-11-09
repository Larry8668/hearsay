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
    private var vpioActive = false
    private var outputListener: AudioObjectPropertyListenerBlock?

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
            tearDownEngine(park: true)
            if let l = outputListener {
                var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
                AudioObjectRemovePropertyListenerBlock(CA.system, &addr, queue, l)
                outputListener = nil
            }
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
        // Voice processing (echo cancellation + noise suppression) costs ~25% of a core on an M4,
        // so it runs only when it can do anything: when the output is a loudspeaker the mic hears.
        let useVPIO = EchoCancellation.shouldEnable()
        vpioActive = useVPIO
        // The last session's stopped voice-processing engine, if still parked on these devices.
        let reused = useVPIO ? VoiceProcessingPark.take(input: CA.defaultInputDevice) : nil
        let engine = reused ?? AVAudioEngine()
        let input = engine.inputNode
        // Must happen BEFORE reading the format / installing the tap: enabling voice processing
        // swaps the underlying AU (VoiceProcessingIO) and changes the input format.
        // Enabling it reconfigures the output device (other apps' audio stops for ~2 × 0.5 s,
        // see docs/PERFORMANCE.md "Audio glitches"); unavoidable, so it happens only at Start.
        if reused != nil {
            Log.info("mic: reusing the parked voice-processing engine")
        } else if useVPIO {
            do {
                try input.setVoiceProcessingEnabled(true)
                // VPIO ducks *all other audio* by default (Zoom's own playback would drop ~15 dB
                // while we record). Ask for the least ducking we can get. (Setting this before
                // enabling made no measurable difference to the output stalls.)
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                Log.warn("mic: voice processing unavailable (\(error.localizedDescription)); capturing raw input without echo cancellation")
            }
        } else {
            Log.info("mic: voice processing off (\(EchoCancellation.current.rawValue); output \(CA.name(CA.defaultOutputDevice) ?? "?"))")
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
        watchOutputDevice()
    }

    /// Plugging headphones in (or out) changes whether echo cancellation is worth running; the
    /// decision is baked into the engine, so rebuild it when the answer changes.
    private func watchOutputDevice() {
        guard outputListener == nil else { return }
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 0.5) {   // let the new device settle
                guard self.continuation != nil, self.engine != nil else { return }
                let want = EchoCancellation.shouldEnable()
                guard want != self.vpioActive else { return }
                Log.info("mic: output changed; echo cancellation \(want ? "on" : "off"), rebuilding engine")
                self.tearDownEngine()
                do { try self.buildEngine() } catch { self.scheduleRetry() }
            }
        }
        if AudioObjectAddPropertyListenerBlock(CA.system, &addr, queue, block) == noErr { outputListener = block }
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

    /// `park`: session end. A voice-processing engine is stopped but not released (releasing it
    /// stutters other apps' audio); VoiceProcessingPark releases it once the output is idle.
    private func tearDownEngine(park: Bool = false) {
        pendingChange?.cancel(); pendingChange = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if park, engine.inputNode.isVoiceProcessingEnabled { VoiceProcessingPark.park(engine, input: deviceID) }
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

/// Setting: when to run Apple's voice processing on the microphone.
enum EchoCancellation: String, CaseIterable {
    /// Only while the default output is a loudspeaker (built-in speakers, monitor, AirPlay).
    case auto
    case always
    case off

    static let key = "echoCancellation"
    static var current: EchoCancellation {
        get { UserDefaults.standard.string(forKey: key).flatMap(EchoCancellation.init) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
    var title: String {
        switch self {
        case .auto: return "Auto (only with speakers)"
        case .always: return "Always"
        case .off: return "Off"
        }
    }
    static func shouldEnable() -> Bool {
        switch current {
        case .always: return true
        case .off: return false
        case .auto: return CA.outputIsLoudspeaker()
        }
    }
}
