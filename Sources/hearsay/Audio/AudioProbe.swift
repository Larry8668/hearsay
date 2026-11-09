import Foundation

/// `hearsay --audio-probe mic|system [--seconds N] [--out /path.wav]` — tests the capture layer
/// without the GUI. Prints one line per second (RMS dBFS, plus active apps for `system`), writes a
/// 16 kHz mono 16-bit WAV and checks that `stop()` left no aggregate device or tap behind.
///
/// TCC note: run from a terminal, the *terminal* is the responsible process and is the one asked
/// for permission. To test hearsay.app's own grants, launch through LaunchServices:
///   open -W --stdout /dev/ttys00N build/hearsay.app --args --audio-probe system
enum AudioProbe {
    static func run(arguments: [String]) -> Int32 {
        var args = arguments[...]
        guard let which = args.popFirst(), which == "mic" || which == "system" else {
            print("usage: hearsay --audio-probe mic|system [--seconds N] [--out /path.wav]")
            return 2
        }
        var seconds = 5.0
        var outPath = NSTemporaryDirectory() + "hearsay-probe-\(which).wav"
        while let a = args.popFirst() {
            switch a {
            case "--seconds": seconds = Double(args.popFirst() ?? "") ?? seconds
            case "--out": outPath = args.popFirst() ?? outPath
            default: print("unknown argument \(a)"); return 2
            }
        }
        print("permissions: microphone=\(Permissions.microphone.rawValue) systemAudio=\(Permissions.systemAudio.rawValue)")

        let source: AudioSource
        if which == "mic" {
            source = MicCapture()
        } else if #available(macOS 14.2, *) {
            source = SystemAudioTap()
        } else {
            print("system audio capture needs macOS 14.2"); return 1
        }

        let stream: AsyncStream<AudioChunk>
        do { stream = try source.start() } catch {
            print("start failed: \(error.localizedDescription)"); return 1
        }
        print("capturing \(seconds) s from \(source.displayName)")
        fflush(stdout)

        let collector = Collector()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for await chunk in stream { collector.add(chunk) }
            done.signal()
        }
        // Spin the main run loop rather than sleeping: by default the HAL delivers its own
        // property updates (device list, tap list) through the main run loop, so a blocked main
        // thread would make a correctly destroyed aggregate still look alive.
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        source.stop()
        if done.wait(timeout: .now() + 2) == .timedOut { print("WARNING: stream did not finish after stop()") }
        collector.finishSecond()

        var leaks = 0
        if #available(macOS 14.2, *) {
            var aggs = SystemAudioTap.leakedAggregates(), taps = CA.allTapIDs()
            let deadline = Date().addingTimeInterval(2)
            while aggs.count + taps.count > 0, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                aggs = SystemAudioTap.leakedAggregates(); taps = CA.allTapIDs()
            }
            leaks = aggs.count + taps.count
            print("after stop: aggregates=\(aggs) taps=\(taps)")
        }
        let samples = collector.samples
        print(String(format: "total %.2f s audio (%d samples, %d chunks), overall RMS %.1f dBFS, timestamps %@",
                     Double(samples.count) / AudioChunk.sampleRate, samples.count, collector.chunkCount,
                     dbfs(samples[...]), collector.gapless ? "gapless+monotonic" : "NOT gapless"))
        do {
            try writeWAV(samples, to: URL(fileURLWithPath: outPath))
            print(outPath)
        } catch {
            print("could not write \(outPath): \(error.localizedDescription)"); return 1
        }
        return leaks == 0 ? 0 : 1
    }

    /// Accumulates chunks and prints a line per second of audio. Only touched from the consumer
    /// task, then read after the stream has finished, so no lock is needed.
    private final class Collector: @unchecked Sendable {
        var samples: [Float] = []
        var chunkCount = 0
        var gapless = true
        private var lastEnd: Date?
        private var secondStart = 0
        private var apps = Set<String>()

        func add(_ c: AudioChunk) {
            if let lastEnd, abs(c.startTime.timeIntervalSince(lastEnd)) > 0.002 { gapless = false }
            lastEnd = c.endTime
            chunkCount += 1
            samples += c.samples
            apps.formUnion(c.sourceApps)
            if samples.count - secondStart >= Int(AudioChunk.sampleRate) { finishSecond() }
        }

        func finishSecond() {
            guard samples.count > secondStart else { return }
            let sec = Double(samples.count) / AudioChunk.sampleRate
            let appText = apps.isEmpty ? "" : "  apps: " + apps.sorted().joined(separator: ", ")
            print(String(format: "%5.1f s  %6.1f dBFS", sec, AudioProbe.dbfs(samples[secondStart...])) + appText)
            fflush(stdout)
            secondStart = samples.count
            apps.removeAll()
        }

    }

    static func dbfs(_ s: ArraySlice<Float>) -> Double {
        guard !s.isEmpty else { return -.infinity }
        let ms = s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(s.count)
        return ms > 0 ? 10 * log10(ms) : -.infinity
    }

    /// Minimal RIFF/WAVE writer: 16 kHz, mono, 16-bit PCM.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let rate = UInt32(AudioChunk.sampleRate), bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        try d.write(to: url)
    }
}
