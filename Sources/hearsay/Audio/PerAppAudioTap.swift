import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// "them", one stream per app: a Core Audio process tap for EACH app that is playing sound, so a
/// video in Zen and a Meet call in Chrome arrive as separate, unmixed audio and can be transcribed
/// (and labelled) separately. Chunks carry the app in `sourceApps`; `PerAppEngine` routes them to
/// one model stream per app.
///
/// Every 500 ms the process list is polled (`kAudioProcessPropertyIsRunningOutput`), grouped by
/// the responsible app (Safari's WebKit.GPU helper → Safari). A new app gets a tap; an app whose
/// helper processes changed gets its tap rebuilt (one short gap); an app that stopped playing
/// loses its tap after ~2 s. Each tap has its own tap-only aggregate device and IOProc, exactly
/// like `SystemAudioTap` (see there for why the aggregate has no sub-device).
///
/// Tabs inside one browser cannot be separated: every browser mixes its tabs before the sound
/// reaches Core Audio (Firefox/Zen in the parent process, Chrome in its audio service, Safari in
/// the GPU process). One browser = one stream.
///
/// Silence: an app holding an open-but-idle output stream still produces IO cycles of zeros.
/// After `silenceCutoff` seconds of silence from an app its chunks are no longer forwarded (the
/// engine has long since ended the line), so idle apps cost nothing downstream; the first voiced
/// chunk resumes forwarding.
///
/// Queues as in `SystemAudioTap`: `queue` owns the Core Audio objects and the poller; `ioQueue`
/// owns the audio path. `queue` may sync onto `ioQueue`, never the reverse.
@available(macOS 14.2, *)
final class PerAppAudioTap: AudioSource {
    let speaker: Speaker = .them
    private(set) var displayName = "System audio, per app"

    /// Apps tapped at once. Beyond this, further apps are ignored until one stops.
    static let maxApps = 6
    /// Polls an app must be absent from the "running output" list before its tap is torn down.
    static let missingPolls = 4
    /// Seconds of silence after which an app's chunks stop being forwarded.
    static let silenceCutoff: TimeInterval = 3
    /// RMS below which a chunk counts as silence (−50 dBFS).
    static let silenceFloor: Float = 0.003

    private let queue = DispatchQueue(label: "hearsay.apptaps", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "hearsay.apptaps.io", qos: .userInitiated)
    private var taps: [String: AppTap] = [:]
    private var missing: [String: Int] = [:]
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var poller: DispatchSourceTimer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var running = false
    private var warnedLimit = false

    func start() throws -> AsyncStream<AudioChunk> {
        if Permissions.systemAudio == .denied { throw AudioSourceError.permissionDenied(.them) }
        stop()
        let (stream, cont) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        queue.sync {
            ioQueue.sync { continuation = cont }
            running = true
            updateDisplayName()
            poll()
            startPoller()
            addOutputListener()
        }
        cont.onTermination = { [weak self] _ in self?.stop() }
        Log.info(.tap, "apptaps: started (\(displayName))")
        return stream
    }

    /// Idempotent.
    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            poller?.cancel(); poller = nil
            removeOutputListener()
            for tap in taps.values { tap.tearDown() }
            taps = [:]; missing = [:]
            ioQueue.sync {
                let c = continuation
                continuation = nil
                c?.onTermination = nil
                c?.finish()
            }
            Log.info(.tap, "apptaps: stopped")
        }
    }

    // MARK: Poller (on `queue`)

    private func startPoller() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        poller = t
    }

    private func poll() {
        guard running else { return }
        var byApp: [String: [AudioObjectID]] = [:]
        for p in SystemAudioTap.runningOutputProcesses() { byApp[p.app, default: []].append(p.object) }

        for (app, objects) in byApp {
            missing[app] = nil
            if let tap = taps[app] {
                guard Set(tap.processes) != Set(objects) else { continue }
                Log.info(.tap, "apptaps: \(app) processes changed; rebuilding its tap")
                do { try tap.rebuild(processes: objects) } catch {
                    Log.warn(.tap, "apptaps: rebuild for \(app) failed: \(error.localizedDescription)")
                    tap.tearDown(); taps[app] = nil
                }
            } else {
                guard taps.count < Self.maxApps else {
                    if !warnedLimit { Log.warn(.tap, "apptaps: more than \(Self.maxApps) apps playing; ignoring \(app)"); warnedLimit = true }
                    continue
                }
                do {
                    taps[app] = try AppTap(app: app, processes: objects, ioQueue: ioQueue) { [weak self] chunk in
                        self?.continuation?.yield(chunk)   // on ioQueue, like `continuation`
                    }
                    Log.info(.tap, "apptaps: tapping \(app) (\(objects.count) process\(objects.count == 1 ? "" : "es"), \(taps.count) app\(taps.count == 1 ? "" : "s") tapped)")
                } catch {
                    Log.warn(.tap, "apptaps: tap for \(app) failed: \(error.localizedDescription)")
                }
            }
        }
        for app in taps.keys where byApp[app] == nil {
            missing[app, default: 0] += 1
            if missing[app]! >= Self.missingPolls {
                taps[app]?.tearDown(); taps[app] = nil; missing[app] = nil
                Log.info(.tap, "apptaps: \(app) stopped playing; tap removed")
            }
        }
    }

    private func updateDisplayName() {
        displayName = CA.name(CA.defaultOutputDevice).map { "System audio, per app (\($0))" } ?? "System audio, per app"
    }

    // MARK: Default output changes

    private func addOutputListener() {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
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

    /// Taps keep streaming across output switches unless their format changed; rebuild those.
    private func outputChanged() {
        guard running else { return }
        updateDisplayName()
        for (app, tap) in taps where tap.formatChanged() {
            Log.info(.tap, "apptaps: tap format changed for \(app); rebuilding")
            do { try tap.rebuild(processes: tap.processes) } catch { tap.tearDown(); taps[app] = nil }
        }
    }
}

/// One app's tap + aggregate + IOProc. Created and torn down on the owner's `queue`; audio runs
/// on `ioQueue`.
@available(macOS 14.2, *)
private final class AppTap {
    let app: String
    private(set) var processes: [AudioObjectID]
    private let ioQueue: DispatchQueue
    private let yield: (AudioChunk) -> Void
    private var tapID = CA.unknown
    private var tapUUID = ""
    private var aggregateID = CA.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var resampler: Resampler16k?
    private let assembler = ChunkAssembler(speaker: .them)
    private var ioCallbacks = 0
    /// Forwarding state (ioQueue): time of the last voiced chunk; nil until the first one.
    private var lastVoiced: Date?
    private var forwarding = false

    init(app: String, processes: [AudioObjectID], ioQueue: DispatchQueue, yield: @escaping (AudioChunk) -> Void) throws {
        self.app = app; self.processes = processes; self.ioQueue = ioQueue; self.yield = yield
        try build()
    }

    func rebuild(processes: [AudioObjectID]) throws {
        tearDown()
        self.processes = processes
        try build()
    }

    func formatChanged() -> Bool {
        guard tapID != CA.unknown, let current = ioQueue.sync(execute: { resampler?.inputFormat }) else { return false }
        return (try? tapFormat()) != current
    }

    private func build() throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.name = "hearsay \(app)"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var id = CA.unknown
        var err = AudioHardwareCreateProcessTap(desc, &id)
        guard err == noErr else { throw AudioSourceError.coreAudio(err, "AudioHardwareCreateProcessTap") }
        tapID = id
        tapUUID = desc.uuid.uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "hearsay tap \(app)",
            kAudioAggregateDeviceUIDKey: SystemAudioTap.aggregateUIDPrefix + "app." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var agg = CA.unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard err == noErr else { tearDown(); throw AudioSourceError.coreAudio(err, "AudioHardwareCreateAggregateDevice") }
        aggregateID = agg

        let format = try tapFormat()
        guard let rs = Resampler16k(inputFormat: format) else {
            tearDown(); throw AudioSourceError.deviceUnavailable("unsupported tap format \(format)")
        }
        ioQueue.sync { resampler = rs }

        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, ioQueue) { [weak self] _, inInput, inInputTime, _, _ in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInput, deallocator: nil) else { return }
            let ts = inInputTime.pointee
            self.process(buffer, hostTime: ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : nil)
        }
        guard err == noErr, let procID else { tearDown(); throw AudioSourceError.coreAudio(err, "AudioDeviceCreateIOProcIDWithBlock") }
        ioProcID = procID
        err = AudioDeviceStart(agg, procID)
        guard err == noErr else { tearDown(); throw AudioSourceError.coreAudio(err, "AudioDeviceStart") }
    }

    private func tapFormat() throws -> AVAudioFormat {
        var asbd = try CA.get(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioSourceError.deviceUnavailable("unreadable tap format \(asbd)")
        }
        return format
    }

    /// On `ioQueue`.
    private func process(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) {
        guard let resampler else { return }
        ioCallbacks += 1
        if ioCallbacks == 1 { Log.info(.tap, "apptaps: first IO buffer from \(app) (\(buffer.frameLength) frames)") }
        let samples = resampler.convert(buffer)
        let start = hostTime.map(CA.date(fromHostTime:))
        for chunk in assembler.append(samples, startTime: start, sourceApps: [app]) { forward(chunk) }
    }

    /// Voiced chunks always go through; silence only for `silenceCutoff` after the last voiced one.
    private func forward(_ chunk: AudioChunk) {
        let voiced = rms(chunk.samples) >= PerAppAudioTap.silenceFloor
        if voiced {
            lastVoiced = chunk.startTime
            forwarding = true
        } else if forwarding, let last = lastVoiced, chunk.startTime.timeIntervalSince(last) > PerAppAudioTap.silenceCutoff {
            forwarding = false
        }
        if forwarding { yield(chunk) }
    }

    private func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for x in s { sum += x * x }
        return (sum / Float(s.count)).squareRoot()
    }

    /// Destroys the Core Audio objects and flushes what the resampler and assembler still hold.
    func tearDown() {
        if aggregateID != CA.unknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != CA.unknown {
            let err = AudioHardwareDestroyAggregateDevice(aggregateID)
            if err != noErr { Log.warn(.tap, "apptaps: destroy aggregate (\(app)) failed: \(err)") }
            aggregateID = CA.unknown
        }
        if tapID != CA.unknown {
            let err = AudioHardwareDestroyProcessTap(tapID)
            if err != noErr { Log.warn(.tap, "apptaps: destroy tap (\(app)) failed: \(err)") }
            tapID = CA.unknown
        }
        ioQueue.sync {
            if let tail = resampler?.flush(), !tail.isEmpty {
                for c in assembler.append(tail, startTime: nil, sourceApps: [app]) { forward(c) }
            }
            if let last = assembler.flush(sourceApps: [app]) { forward(last) }
            resampler = nil
        }
    }
}
