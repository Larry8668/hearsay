import FluidAudio
import Foundation

/// `hearsay --transcribe file.wav [--variant NAME] [--realtime] [--two other.wav] [--no-split]
///  [--diarize [sortformer|lseend|lseend-ami]] [--enrol me.wav]`
///
/// Runs the real engine on a 16 kHz mono WAV without the GUI and prints what the session layer
/// would receive, plus speed and memory numbers. `--two` runs a second engine instance (speaker
/// `them`) on another file at the same time, which is how me + them run in the app. `--no-split`
/// turns off the mid-speech line cuts (sentence / clause / length) to compare the text.
/// `--diarize` tells speakers apart on both streams (lines print their speaker id) with the
/// given diarizer, and `--enrol` plays a clip of one voice into it first so that voice is "me".
/// This is the one place allowed to `print`: its output IS the product.
enum EngineProbe {
    static func run(arguments: [String]) -> Int32 {
        var files: [String] = [], variant: StreamingModelVariant?, realtime = false, passes = 1, split = true
        var diarizer: DiarizerKind?, enrol: String?
        var it = arguments.makeIterator()
        while let a = it.next() {
            switch a {
            case "--realtime": realtime = true
            case "--no-split": split = false
            case "--diarize":
                diarizer = DiarizerKind.configured()
                if let raw = it.next() {
                    if let k = DiarizerKind(rawValue: raw) { diarizer = k } else { files.append(raw) }
                }
            case "--enrol": enrol = it.next()
            // Several sessions on the same engines: proves start-after-stop works without a reload.
            case "--passes": passes = max(1, Int(it.next() ?? "") ?? 1)
            case "--variant":
                guard let raw = it.next(), let v = StreamingModelVariant(rawValue: raw) else {
                    print("unknown variant. one of: " + StreamingModelVariant.allCases.map(\.rawValue).joined(separator: ", "))
                    return 2
                }
                variant = v
            case "--two": if let f = it.next() { files.append(f) }
            default: files.append(a)
            }
        }
        guard !files.isEmpty else {
            print("usage: hearsay --transcribe file.wav [--variant NAME] [--realtime] [--two other.wav] [--passes N] [--no-split] [--diarize [KIND]] [--enrol me.wav]")
            return 2
        }
        var clip: [Float]?
        if let enrol {
            guard case .success(let s) = WAV.read(enrol) else { print("\(enrol): need 16 kHz mono WAV"); return 2 }
            clip = s
        }
        var audio: [[Float]] = []
        for f in files {
            switch WAV.read(f) {
            case .success(let s): audio.append(s)
            case .failure(let e):
                print("\(f): \(e.message)")
                if e.convertible {
                    print("convert with: ffmpeg -y -i '\(f)' -ar 16000 -ac 1 -c:a pcm_s16le out.wav")
                }
                return 2
            }
        }
        let sem = DispatchSemaphore(value: 0)
        let code = Box()
        Task.detached {
            if let diarizer {
                await DiarizerRegistry.shared.configure(mode: .all, kind: diarizer, clip: clip)
                let t0 = Date()
                let shown = Box()
                do {
                    try await DiarizerRegistry.shared.prepare { state in
                        if case .downloading(let f) = state, f >= 0, Int32(f * 100) > shown.value {
                            shown.value = Int32(f * 100)
                            FileHandle.standardError.write("\rdownloading diarizer \(shown.value)%".data(using: .utf8)!)
                        }
                    }
                    print(String(format: "diarizer: %@ ready in %.1f s; on disk %.0f MB", diarizer.rawValue,
                                 Date().timeIntervalSince(t0), Double(ModelStore.diskSize(diarizer)) / 1_048_576))
                } catch {
                    print("diarizer: \(error.localizedDescription)"); code.value = 1; sem.signal(); return
                }
            }
            code.value = await session(audio: audio, variant: variant ?? ParakeetEngine.configuredVariant(),
                                       realtime: realtime, passes: passes, split: split)
            sem.signal()
        }
        sem.wait()
        return code.value
    }

    private final class Box: @unchecked Sendable { var value: Int32 = 0 }

    private static func session(audio: [[Float]], variant: StreamingModelVariant, realtime: Bool, passes: Int,
                                split: Bool) async -> Int32 {
        var cfg = UtteranceTracker.Config()
        if !split { cfg.sentenceAfter = .infinity; cfg.clauseAfter = .infinity; cfg.clauseWords = .max; cfg.maxUtterance = .infinity }
        let engines = audio.indices.map { _ in ParakeetEngine(variant: variant, tracker: cfg) }
        print("variant: \(variant.rawValue) (\(variant.displayName))  models: \(ModelStore.directory(for: variant).path)")
        let downloaded = ModelStore.isDownloaded(variant)
        let tLoad = Date()
        let shown = Box()
        do {
            for e in engines {
                try await e.prepare { state in
                    if case .downloading(let f) = state, f >= 0, Int32(f * 100) > shown.value {
                        shown.value = Int32(f * 100)
                        FileHandle.standardError.write("\rdownloading \(shown.value)%".data(using: .utf8)!)
                    }
                }
            }
        } catch {
            print("prepare failed: \(error.localizedDescription)")
            return 1
        }
        let loadSec = Date().timeIntervalSince(tLoad)
        print(String(format: "%@ in %.1f s; on disk %.0f MB; RSS after load %.0f MB",
                     downloaded ? "loaded" : "downloaded + loaded", loadSec,
                     Double(ModelStore.diskSize(variant)) / 1_048_576, Memory.footprintMB()))
        for p in 1...passes {
            if passes > 1 { print("=== pass \(p)") }
            guard await pass(engines: engines, audio: audio, realtime: realtime) else { return 1 }
        }
        print(String(format: "peak RSS %.0f MB; peak footprint %.0f MB; footprint now %.0f MB",
                     Memory.peakRSSMB(), Memory.peakFootprintMB(), Memory.footprintMB()))
        return 0
    }

    private static func pass(engines: [ParakeetEngine], audio: [[Float]], realtime: Bool) async -> Bool {
        let speakers: [Speaker] = [.me, .them]
        let t0 = Date()
        let firstPartial = Box2()
        var listeners: [Task<[Double], Never>] = []
        for (i, e) in engines.enumerated() {
            let speaker = speakers[i]
            guard let events = try? await e.start(speaker: speaker) else { print("start failed"); return false }
            listeners.append(Task.detached {
                var finalLags: [Double] = []
                let tag = engines.count > 1 ? "\(speaker.rawValue): " : ""
                for await ev in events {
                    switch ev {
                    case .partial(let text, _, _, let who):
                        firstPartial.mark(Date().timeIntervalSince(t0))
                        print("~ \(tag)\(who.map { "\($0) " } ?? "")\(text)")
                    case .final(let l):
                        finalLags.append(Date().timeIntervalSince(l.end))
                        let app = l.sourceApp.map { " (\($0))" } ?? ""
                        print(String(format: "[%.2f–%.2f] %@%@%@%@", l.start.timeIntervalSince(t0),
                                     l.end.timeIntervalSince(t0), tag, l.speakerID.map { "\($0): " } ?? "", l.text, app))
                    case .warning(let w): print("! \(tag)\(w)")
                    }
                }
                return finalLags
            })
        }

        // Feed every file in parallel as 100 ms chunks on one shared timeline. A shorter file is
        // continued with silence, like a live source that keeps delivering after people stop talking.
        let chunk = 1600
        let longest = audio.map(\.count).max() ?? 0
        var offset = 0
        while offset < longest {
            for (i, samples) in audio.enumerated() {
                let slice = offset < samples.count
                    ? Array(samples[offset..<min(offset + chunk, samples.count)])
                    : [Float](repeating: 0, count: min(chunk, longest - offset))
                let start = t0.addingTimeInterval(Double(offset) / AudioChunk.sampleRate)
                await engines[i].feed(AudioChunk(samples: slice, startTime: start, speaker: speakers[i],
                                                 sourceApps: speakers[i] == .them ? ["dev.hearsay.probe"] : []))
            }
            offset += chunk
            if realtime {
                let due = t0.addingTimeInterval(Double(offset) / AudioChunk.sampleRate)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            }
        }
        let tFed = Date()
        for e in engines { await e.stop() }
        var lags: [Double] = []
        for l in listeners { lags += await l.value }
        let wall = Date().timeIntervalSince(t0)

        let audioSec = Double(longest) / AudioChunk.sampleRate
        print("---")
        if realtime {
            // Paced input makes wall/audio ≈ 1 by construction; run without --realtime for RTF.
            print(String(format: "audio %.1f s × %d stream(s); wall %.2f s; flush after last chunk %.0f ms",
                         audioSec, engines.count, wall, Date().timeIntervalSince(tFed) * 1000))
        } else {
            print(String(format: "audio %.1f s × %d stream(s); wall %.2f s; RTF %.3f", audioSec, engines.count, wall, wall / audioSec))
        }
        print(firstPartial.value.map { String(format: "time to first partial: %.0f ms", $0 * 1000) } ?? "no partials")
        if realtime, !lags.isEmpty {
            print(String(format: "final emitted after line end: mean %.2f s, max %.2f s", lags.reduce(0, +) / Double(lags.count), lags.max()!))
        }
        return true
    }

    private final class Box2: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var value: Double?
        func mark(_ v: Double) { lock.lock(); if value == nil { value = v }; lock.unlock() }
    }
}

/// Minimal RIFF/WAVE reader: 16-bit PCM or 32-bit float, mono, 16 kHz only.
enum WAV {
    struct Failure: Error { let message: String; let convertible: Bool }

    static func read(_ path: String) -> Result<[Float], Failure> {
        guard let d = FileManager.default.contents(atPath: path) else {
            return .failure(Failure(message: "cannot read file", convertible: false))
        }
        return parse(d)
    }

    static func parse(_ d: Data) -> Result<[Float], Failure> {
        let b = [UInt8](d)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 12, b[0..<4] == [0x52, 0x49, 0x46, 0x46], b[8..<12] == [0x57, 0x41, 0x56, 0x45] else {
            return .failure(Failure(message: "not a RIFF/WAVE file", convertible: true))
        }
        var fmt: (format: Int, channels: Int, rate: Int, bits: Int)?
        var o = 12
        while o + 8 <= b.count {
            let id = String(bytes: b[o..<o + 4], encoding: .ascii) ?? ""
            let size = u32(o + 4), body = o + 8
            if id == "fmt ", body + 16 <= b.count {
                var format = u16(body)
                if format == 0xFFFE, size >= 26 { format = u16(body + 24) }  // WAVE_FORMAT_EXTENSIBLE subformat
                fmt = (format, u16(body + 2), u32(body + 4), u16(body + 14))
            } else if id == "data", let f = fmt {
                guard f.channels == 1, f.rate == 16_000, (f.format == 1 && f.bits == 16) || (f.format == 3 && f.bits == 32) else {
                    return .failure(Failure(message: "need 16 kHz mono 16-bit PCM (got \(f.rate) Hz, \(f.channels) ch, \(f.bits)-bit, format \(f.format))", convertible: true))
                }
                let end = min(body + size, b.count)
                var out: [Float] = []
                out.reserveCapacity((end - body) / (f.bits / 8))
                var p = body
                if f.bits == 16 {
                    while p + 1 < end { out.append(Float(Int16(bitPattern: UInt16(u16(p)))) / 32768); p += 2 }
                } else {
                    while p + 3 < end { out.append(Float(bitPattern: UInt32(u32(p)))); p += 4 }
                }
                return .success(out)
            }
            o = body + size + (size & 1)
        }
        return .failure(Failure(message: "no fmt/data chunk", convertible: true))
    }
}

enum Memory {
    /// Peak resident set size of this process (ru_maxrss is bytes on macOS).
    static func peakRSSMB() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_maxrss) / 1_048_576
    }

    /// Current physical footprint (what Activity Monitor's "Memory" column shows). RSS overstates
    /// CoreML: it counts the memory-mapped model files touched during the first ANE compile.
    static func footprintMB() -> Double { vmInfo().map { Double($0.phys_footprint) / 1_048_576 } ?? 0 }
    static func peakFootprintMB() -> Double { vmInfo().map { Double($0.ledger_phys_footprint_peak) / 1_048_576 } ?? 0 }

    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }
}
