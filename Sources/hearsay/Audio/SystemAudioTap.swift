import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// "them": everything the Mac plays, captured with a Core Audio process tap (macOS 14.2+).
///
/// Shape of the graph: a global stereo tap (all processes except us) → a *private* aggregate
/// device containing only that tap → an IOProc block on a serial queue.
/// AVAudioEngine is deliberately not used: pointed at a tap aggregate it starts "successfully"
/// and never delivers a buffer.
///
/// The aggregate has NO sub-device. The textbook recipe (insidegui/AudioCap) adds the default
/// output as main/clock sub-device, but measured on macOS 27.2: with a virtual output (BlackHole,
/// and presumably the Zoom/Teams virtual devices) as default, that aggregate never runs a single
/// IO cycle; and every output switch forces a rebuild that loses ~0.5 s of audio. A tap-only
/// aggregate is clocked by the tap, works on every output tried, and keeps streaming gaplessly
/// across default-output switches without being touched.
///
/// IO only starts once some process actually plays audio (an idle Mac produces no tap cycles),
/// so the first chunk can arrive long after start(), and chunk start times jump forward across
/// idle periods (see ChunkAssembler).
///
/// Without the "System Audio Recording Only" grant every call below still succeeds; the tap
/// then delivers zeros or no buffers at all. A silent/empty stream = missing permission.
///
/// Two serial queues, no locks: `queue` owns the Core Audio objects (create / destroy / rebuild,
/// the default-output listener); `ioQueue` owns the audio path (IOProc, resampler, assembler,
/// continuation, app poller). They must be separate: AudioDeviceStop waits for an in-flight
/// IOProc block, so stopping from the IOProc's own queue deadlocks. `queue` may sync onto
/// `ioQueue`, never the reverse.
@available(macOS 14.2, *)
final class SystemAudioTap: AudioSource {
    let speaker: Speaker = .them
    private(set) var displayName = "System audio"

    private let queue = DispatchQueue(label: "hearsay.systemtap", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "hearsay.systemtap.io", qos: .userInitiated)
    private var tapID = CA.unknown
    private var aggregateID = CA.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var resampler: Resampler16k?
    private var assembler = ChunkAssembler(speaker: .them)
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var appTimer: DispatchSourceTimer?
    private var sourceApps: [String] = []
    private var ioCallbacks = 0

    /// UID prefix of the aggregates we create; `leakedAggregates()` looks for it.
    static let aggregateUIDPrefix = "dev.hearsay.systemtap."

    func start() throws -> AsyncStream<AudioChunk> {
        if Permissions.systemAudio == .denied { throw AudioSourceError.permissionDenied(.them) }
        stop()
        let (stream, cont) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        try queue.sync {
            ioQueue.sync { continuation = cont; assembler = ChunkAssembler(speaker: .them) }
            do {
                try buildTap()
                try buildAggregate()
            } catch {
                tearDown()
                ioQueue.sync { continuation = nil }
                throw error
            }
            addOutputListener()
            startAppPoller()
        }
        cont.onTermination = { [weak self] _ in self?.stop() }
        return stream
    }

    /// Idempotent. Destroys everything in reverse order of creation.
    func stop() {
        queue.sync {
            guard tapID != CA.unknown || aggregateID != CA.unknown else { return }
            removeOutputListener()
            appTimer?.cancel(); appTimer = nil
            tearDown()
            ioQueue.sync { finishStream() }
        }
    }

    private func finishStream() {
        if let tail = resampler?.flush(), !tail.isEmpty {
            for c in assembler.append(tail, startTime: nil, sourceApps: sourceApps) { continuation?.yield(c) }
        }
        if let last = assembler.flush(sourceApps: sourceApps) { continuation?.yield(last) }
        resampler = nil
        let c = continuation
        continuation = nil
        c?.onTermination = nil   // finish() would call it synchronously, re-entering this queue
        c?.finish()
        Log.info("systemtap: stopped after \(ioCallbacks) IO callbacks")
        ioCallbacks = 0
    }

    // MARK: Tap + aggregate (on `queue`)

    private func buildTap() throws {
        // Exclude our own process so nothing hearsay plays (alerts, previews) is transcribed.
        // The process object only exists once we have touched audio; if it doesn't yet, there
        // is nothing of ours to exclude.
        var pid = getpid()
        let own = (try? CA.get(CA.system, kAudioHardwarePropertyTranslatePIDToProcessObject, initial: CA.unknown,
                               qualifier: &pid, qualifierSize: UInt32(MemoryLayout<pid_t>.size))) ?? CA.unknown
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: own == CA.unknown ? [] : [own])
        desc.name = "hearsay system audio"
        desc.uuid = UUID()
        desc.isPrivate = true          // invisible to other processes
        desc.muteBehavior = .unmuted   // the user must still hear the call
        var id = CA.unknown
        let err = AudioHardwareCreateProcessTap(desc, &id)
        guard err == noErr else { throw AudioSourceError.coreAudio(err, "AudioHardwareCreateProcessTap") }
        tapID = id
        tapUUID = desc.uuid.uuidString
    }
    private var tapUUID = ""

    private func buildAggregate() throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "hearsay system tap",
            kAudioAggregateDeviceUIDKey: SystemAudioTap.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,     // only this process can see it; dies with us
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            // The tap is referenced by the UUID we put in its description. kAudioTapPropertyUID
            // looks equivalent but aggregates built from it deliver nothing on some releases.
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var agg = CA.unknown
        var err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard err == noErr else { throw AudioSourceError.coreAudio(err, "AudioHardwareCreateAggregateDevice") }
        aggregateID = agg

        // The tap's format is authoritative for what the IOProc receives (48 kHz stereo Float32
        // non-interleaved in every test, but read it rather than assume it).
        let format = try tapFormat()
        guard let rs = Resampler16k(inputFormat: format) else {
            throw AudioSourceError.deviceUnavailable("unsupported tap format \(format)")
        }
        ioQueue.sync { resampler = rs }

        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, ioQueue) { [weak self] _, inInput, inInputTime, _, _ in
            // Runs on `ioQueue` (Core Audio copies the input for us when a queue is given), so
            // the buffer list is only valid for the duration of this call: convert it here.
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInput, deallocator: nil) else { return }
            let ts = inInputTime.pointee
            let host: UInt64? = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : nil
            self.process(buffer, hostTime: host)
        }
        guard err == noErr, let procID else { throw AudioSourceError.coreAudio(err, "AudioDeviceCreateIOProcIDWithBlock") }
        ioProcID = procID
        err = AudioDeviceStart(agg, procID)
        guard err == noErr else { throw AudioSourceError.coreAudio(err, "AudioDeviceStart") }
        updateDisplayName()
        Log.info("systemtap: started (\(displayName)) tap \(Int(format.sampleRate)) Hz × \(format.channelCount) ch")
    }

    private func tapFormat() throws -> AVAudioFormat {
        var asbd = try CA.get(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioSourceError.deviceUnavailable("unreadable tap format \(asbd)")
        }
        return format
    }

    private func updateDisplayName() {
        displayName = CA.name(CA.defaultOutputDevice).map { "System audio (\($0))" } ?? "System audio"
    }

    private func tearDownAggregate() {
        if aggregateID != CA.unknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != CA.unknown {
            let err = AudioHardwareDestroyAggregateDevice(aggregateID)
            if err != noErr { Log.warn("systemtap: destroy aggregate failed: \(err)") }
            aggregateID = CA.unknown
        }
    }

    private func tearDown() {
        tearDownAggregate()
        if tapID != CA.unknown {
            let err = AudioHardwareDestroyProcessTap(tapID)
            if err != noErr { Log.warn("systemtap: destroy tap failed: \(err)") }
            tapID = CA.unknown
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) {
        guard let continuation, let resampler else { return }
        ioCallbacks += 1
        if ioCallbacks == 1 { Log.info("systemtap: first IO buffer (\(buffer.frameLength) frames)") }
        let samples = resampler.convert(buffer)
        let start = hostTime.map(CA.date(fromHostTime:))
        for chunk in assembler.append(samples, startTime: start, sourceApps: sourceApps) { continuation.yield(chunk) }
    }

    // MARK: Default output changes (AirPods connect, HDMI, …)

    private func addOutputListener() {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        // Delivered on a global queue and hopped onto `queue`: removing a listener from the queue
        // it is delivered on can wait for an in-flight callback, i.e. deadlock in stop().
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async { self.outputChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(CA.system, &addr, .global(qos: .utility), block) == noErr { outputListener = block }
    }

    private func removeOutputListener() {
        guard let block = outputListener else { return }
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(CA.system, &addr, .global(qos: .utility), block)
        outputListener = nil
    }

    /// The tap-only aggregate keeps streaming across output switches (verified with speakers ↔
    /// BlackHole), so normally this only renames the source. If the tap's format changed with the
    /// device (e.g. a different sample rate), the IOProc would misread buffers: rebuild then.
    private func outputChanged() {
        guard tapID != CA.unknown else { return }
        updateDisplayName()
        let current = ioQueue.sync { resampler?.inputFormat }
        let new = try? tapFormat()
        if aggregateID != CA.unknown, new == current {
            Log.info("systemtap: default output changed; now \(displayName), tap format unchanged")
            return
        }
        Log.info("systemtap: default output changed; tap format now \(new.map { "\($0)" } ?? "unknown"); rebuilding aggregate")
        tearDownAggregate()
        ioQueue.sync {
            if let tail = resampler?.flush(), !tail.isEmpty {
                for c in assembler.append(tail, startTime: nil, sourceApps: sourceApps) { continuation?.yield(c) }
            }
        }
        do { try buildAggregate() } catch {
            Log.error("systemtap: rebuild failed: \(error.localizedDescription); waiting for the next output change")
            tearDownAggregate()
        }
    }

    // MARK: Which apps are making sound

    private func startAppPoller() {
        let t = DispatchSource.makeTimerSource(queue: ioQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.sourceApps = SystemAudioTap.activeOutputApps() }
        t.resume()
        appTimer = t
    }

    /// Bundle IDs (or executable names for bare CLI tools like `afplay`) of processes whose audio
    /// output is running right now, excluding hearsay itself. Note that browsers often play from
    /// a helper (Safari → "com.apple.WebKit.GPU", Chrome → "com.google.Chrome.helper"), and that
    /// "running output" includes apps holding an idle-but-open output stream.
    static func activeOutputApps() -> [String] {
        let own = getpid()
        let objects = (try? CA.getArray(CA.system, kAudioHardwarePropertyProcessObjectList, zero: CA.unknown)) ?? []
        var result: [String] = []
        for obj in objects {
            let running = (try? CA.get(obj, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            guard running != 0 else { continue }
            let pid = (try? CA.get(obj, kAudioProcessPropertyPID, initial: pid_t(-1))) ?? -1
            guard pid != own else { continue }
            var name = ""
            // Browsers and Electron apps play from a helper (Safari → com.apple.WebKit.GPU, Chrome →
            // com.google.Chrome.helper). The "responsible" process is the app the user would name,
            // and it is also the one TCC attributes the sound to.
            if pid > 0, let owner = responsibleApp(for: pid) { name = owner }
            if name.isEmpty { name = CA.string(obj, kAudioProcessPropertyBundleID) ?? "" }
            if name.isEmpty, pid > 0 {
                name = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? executableName(pid) ?? ""
            }
            if !name.isEmpty, !result.contains(name) { result.append(name) }
        }
        return result
    }

    /// Bundle ID of the app responsible for `pid` (itself, or the parent app of a helper), via the
    /// same libquarantine call TCC uses. Private but long-stable (10.14+); nil if unavailable, if
    /// the responsible process is `pid` itself and has no bundle, or if it's launchd.
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFor: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()
    private static func responsibleApp(for pid: pid_t) -> String? {
        guard let fn = responsibleFor else { return nil }
        let owner = fn(pid)
        guard owner > 1 else { return nil }
        return NSRunningApplication(processIdentifier: owner)?.bundleIdentifier
    }

    private static func executableName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf)).lastPathComponent
    }

    /// Our aggregates still alive in this process. Used by the probe to prove `stop()` leaks nothing.
    static func leakedAggregates() -> [String] {
        CA.allDeviceUIDs().filter { $0.hasPrefix(aggregateUIDPrefix) }
    }
}
