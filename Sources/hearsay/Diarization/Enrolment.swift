import AppKit
import Foundation

/// The user's own voice, so the diarizer can label it "me" and everyone else "Speaker N".
///
/// Settings ▸ "Learn my voice…" records `seconds` of the microphone into
/// `~/Library/Application Support/hearsay/voice/me.wav` (16 kHz mono PCM, so it can be listened
/// to or replaced by hand). `DiarizerRegistry` plays it into every new microphone-lane diarizer
/// before live audio (Sortformer's speaker cache then holds that voice in a slot). The clip is
/// not a voiceprint: it only primes the current session's model and never leaves the Mac.
enum Enrolment {
    static let seconds: TimeInterval = 10
    /// A clip needs this much actual speech (20 ms frames above the tracker's energy threshold).
    static let minimumSpeech: TimeInterval = 3

    static var clipURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hearsay/voice/me.wav")
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: clipURL.path) }

    static var date: Date? {
        (try? FileManager.default.attributesOfItem(atPath: clipURL.path))?[.modificationDate] as? Date
    }

    static func load() -> [Float]? {
        guard exists, case .success(let samples) = WAV.read(clipURL.path), !samples.isEmpty else { return nil }
        return samples
    }

    static func save(_ samples: [Float]) throws {
        try FileManager.default.createDirectory(at: clipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WAV.data(samples).write(to: clipURL, options: .atomic)
        Log.info("enrolment: saved \(String(format: "%.1f", Double(samples.count) / AudioChunk.sampleRate)) s to \(clipURL.path)")
    }

    static func forget() {
        try? FileManager.default.removeItem(at: clipURL)
        Log.info("enrolment: forgotten")
    }

    /// Seconds of voiced audio in the clip, the same way `UtteranceTracker` hears it.
    static func speechSeconds(_ samples: [Float]) -> TimeInterval {
        let frame = 320, threshold: Float = 0.006
        var voiced = 0, i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            if (sum / Float(frame)).squareRoot() >= threshold { voiced += 1 }
            i += frame
        }
        return Double(voiced * frame) / AudioChunk.sampleRate
    }
}

/// Records the enrolment clip from the microphone with a small countdown panel. One at a time;
/// only while no session is running (the lane would otherwise own the microphone).
@MainActor
final class EnrolmentRecorder {
    enum Failure: Error, LocalizedError {
        case busy, tooQuiet(TimeInterval)
        var errorDescription: String? {
            switch self {
            case .busy: return "Stop listening first, then learn your voice."
            case .tooQuiet(let s): return String(format: "Heard only %.0f s of speech; try again and keep talking.", s)
            }
        }
    }

    private var panel: NSPanel?
    private var label: NSTextField?
    private var running = false

    /// Records `Enrolment.seconds`, saves the clip and calls `completion` with the clip's speech
    /// length. `canStart` says whether the microphone is free.
    func start(canStart: Bool, completion: @escaping (Result<TimeInterval, Error>) -> Void) {
        guard !running else { return }
        guard canStart else { completion(.failure(Failure.busy)); return }
        running = true
        showPanel()
        let source = Wiring.makeSource(.me)
        let box = SourceBox(source: source)
        Task { [weak self] in
            var samples: [Float] = []
            let want = Int(Enrolment.seconds * AudioChunk.sampleRate)
            do {
                let chunks = try await Task.detached(priority: .userInitiated) { try box.source.start() }.value
                var shown = -1
                for await chunk in chunks {
                    samples += chunk.samples
                    let left = Int((Double(want - samples.count) / AudioChunk.sampleRate).rounded(.up))
                    if left != shown { shown = left; self?.label?.stringValue = "Speak normally… \(max(left, 0)) s" }
                    if samples.count >= want { break }
                }
                source.stop()
                let speech = Enrolment.speechSeconds(samples)
                guard speech >= Enrolment.minimumSpeech else { throw Failure.tooQuiet(speech) }
                try Enrolment.save(Array(samples.prefix(want)))
                self?.finish(); completion(.success(speech))
            } catch {
                source.stop()
                Log.error("enrolment: \(error.localizedDescription)")
                self?.finish(); completion(.failure(error))
            }
        }
    }

    private func showPanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
                        styleMask: [.titled, .nonactivatingPanel, .hudWindow, .utilityWindow], backing: .buffered, defer: false)
        p.title = "Learn my voice"
        p.level = .floating
        p.isReleasedWhenClosed = false
        let text = NSTextField(labelWithString: "Starting the microphone…")
        text.font = .systemFont(ofSize: 15, weight: .medium)
        text.alignment = .center
        text.frame = NSRect(x: 10, y: 45, width: 280, height: 24)
        let hint = NSTextField(labelWithString: "Read anything aloud for 10 seconds.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 10, y: 18, width: 280, height: 18)
        p.contentView?.addSubview(text)
        p.contentView?.addSubview(hint)
        p.center()
        p.orderFrontRegardless()
        panel = p
        label = text
    }

    private func finish() {
        panel?.close()
        panel = nil
        label = nil
        running = false
    }

    private struct SourceBox: @unchecked Sendable { let source: AudioSource }
}

extension WAV {
    /// 16 kHz mono 16-bit PCM RIFF/WAVE bytes for `samples` (−1…1).
    static func data(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = samples.count * 2
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() { pcm[i] = Int16(max(-32768, min(32767, (s * 32767).rounded()))) }
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}
