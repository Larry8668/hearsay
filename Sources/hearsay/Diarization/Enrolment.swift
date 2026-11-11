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
    static let seconds: TimeInterval = 15
    /// A clip needs this much actual speech (20 ms frames above the tracker's energy threshold).
    static let minimumSpeech: TimeInterval = 5

    /// What the panel asks the user to read, about 15 s aloud. Taken from the two standard sets
    /// speech research uses to cover the sounds of English, so a short clip still exercises most
    /// of a voice:
    /// - TIMIT's two "calibration" sentences (SA1, SA2), which every one of TIMIT's 630 speakers
    ///   read precisely because they bring out how a person pronounces things;
    /// - two of the phonetically balanced Harvard sentences (IEEE Recommended Practice for Speech
    ///   Quality Measurements, 1969, Appendix C; lists 1 and 2), picked at random each time.
    static let calibration = [
        "She had your dark suit in greasy wash water all year.",
        "Don't ask me to carry an oily rag like that.",
    ]
    static let harvard = [
        "The birch canoe slid on the smooth planks.", "Glue the sheet to the dark blue background.",
        "It's easy to tell the depth of a well.", "These days a chicken leg is a rare dish.",
        "Rice is often served in round bowls.", "The juice of lemons makes fine punch.",
        "The box was thrown beside the parked truck.", "The hogs were fed chopped corn and garbage.",
        "Four hours of steady work faced us.", "A large size in stockings is hard to sell.",
        "The boy was there when the sun rose.", "A rod is used to catch pink salmon.",
        "The source of the huge river is the clear spring.", "Kick the ball straight and follow through.",
        "Help the woman get back to her feet.", "A pot of tea helps to pass the evening.",
        "Smoky fires lack flame and heat.", "The soft cushion broke the man's fall.",
        "The salt breeze came across from the sea.", "The girl at the booth sold fifty bonds.",
    ]

    static func passage() -> String { (calibration + harvard.shuffled().prefix(2)).joined(separator: " ") }

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
            case .tooQuiet(let s): return String(format: "Heard only %.0f s of speech. Try again and read the whole passage aloud.", s)
            }
        }
    }

    private var panel: NSPanel?
    private var status: NSTextField?
    private var meter: NSLevelIndicator?
    private var startButton: NSButton?
    private var task: Task<Void, Never>?
    private var source: AudioSource?
    private var completion: ((Result<TimeInterval, Error>) -> Void)?
    private var running = false

    /// Shows the panel with a passage to read. Recording starts only when the user presses Start,
    /// so nobody is timed while still reading the instructions. `canStart` says whether the
    /// microphone is free.
    func start(canStart: Bool, completion: @escaping (Result<TimeInterval, Error>) -> Void) {
        guard !running else { panel?.orderFrontRegardless(); return }
        guard canStart else { completion(.failure(Failure.busy)); return }
        running = true
        self.completion = completion
        showPanel(passage: Enrolment.passage())
    }

    /// Dev aid (`HEARSAY_UI_SCRIPT=…,enrolstart@N`): presses Start.
    func pressStart() { if startButton?.isEnabled == true { record() } }

    @objc private func record() {
        status?.textColor = .secondaryLabelColor
        startButton?.isEnabled = false
        startButton?.title = "Recording…"
        status?.stringValue = "Starting the microphone…"
        let source = Wiring.makeSource(.me)
        self.source = source
        let box = SourceBox(source: source)
        task = Task { [weak self] in
            var samples: [Float] = []
            let want = Int(Enrolment.seconds * AudioChunk.sampleRate)
            do {
                let chunks = try await Task.detached(priority: .userInitiated) { try box.source.start() }.value
                var shown = -1
                for await chunk in chunks {
                    if Task.isCancelled { break }
                    samples += chunk.samples
                    let level = Double(LevelMeter.level(rms: LevelMeter.rms(chunk.samples))) * 10
                    let left = Int((Double(want - samples.count) / AudioChunk.sampleRate).rounded(.up))
                    let changed = left != shown
                    shown = left
                    // AppKit views only from the main thread; this task runs on the cooperative pool.
                    await MainActor.run {
                        self?.meter?.doubleValue = level
                        if changed { self?.status?.stringValue = "Read the text aloud… \(max(left, 0)) s left" }
                    }
                    if samples.count >= want { break }
                }
                source.stop()
                if Task.isCancelled { throw CancellationError() }
                let speech = Enrolment.speechSeconds(samples)
                guard speech >= Enrolment.minimumSpeech else { throw Failure.tooQuiet(speech) }
                try Enrolment.save(Array(samples.prefix(want)))
                await MainActor.run { self?.done(.success(speech)) }
            } catch is CancellationError {
                source.stop()
                Log.info(.diarize, "enrolment: cancelled")
                await MainActor.run { self?.done(nil) }
            } catch {
                source.stop()
                Log.error(.diarize, "enrolment: \(error.localizedDescription)")
                await MainActor.run { self?.done(.failure(error)) }
            }
        }
    }

    @objc private func cancel() {
        if let task { task.cancel(); source?.stop() } else { close() }
    }

    private func showPanel(passage: String) {
        let w: CGFloat = 420, h: CGFloat = 250
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        p.title = "Learn my voice"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        guard let root = p.contentView else { return }

        let intro = NSTextField(wrappingLabelWithString: "Press Start, then read this aloud in your normal voice, about as far from the Mac as you usually sit:")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.frame = NSRect(x: 20, y: h - 58, width: w - 40, height: 36)

        let text = NSTextField(wrappingLabelWithString: "“\(passage)”")
        text.font = .systemFont(ofSize: 15, weight: .medium)
        text.frame = NSRect(x: 20, y: 96, width: w - 40, height: h - 58 - 104)

        let meter = NSLevelIndicator(frame: NSRect(x: 20, y: 70, width: w - 40, height: 14))
        meter.levelIndicatorStyle = .continuousCapacity
        meter.minValue = 0; meter.maxValue = 10
        meter.warningValue = 11; meter.criticalValue = 11

        let status = NSTextField(labelWithString: "Takes \(Int(Enrolment.seconds)) seconds. Stays on this Mac.")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 20, y: 44, width: w - 40, height: 16)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: w - 196, y: 10, width: 84, height: 28)
        cancel.keyEquivalent = "\u{1b}"
        let start = NSButton(title: "Start", target: self, action: #selector(record))
        start.frame = NSRect(x: w - 104, y: 10, width: 84, height: 28)
        start.keyEquivalent = "\r"
        start.bezelColor = .controlAccentColor

        for v in [intro, text, meter, status, cancel, start] { root.addSubview(v) }
        p.center()
        p.orderFrontRegardless()
        panel = p; self.status = status; self.meter = meter; startButton = start
    }

    /// `nil`: cancelled. A failure keeps the panel open with the reason and a Try again button, so
    /// the outcome is never only a line somewhere else; success shows a tick, then closes.
    private func done(_ result: Result<TimeInterval, Error>?) {
        task = nil; source = nil
        meter?.doubleValue = 0
        switch result {
        case .failure(let error)?:
            status?.stringValue = error.localizedDescription
            status?.textColor = .systemOrange
            startButton?.title = "Try again"
            startButton?.isEnabled = true
            completion?(.failure(error))
            return
        case .success(let speech)?:
            status?.stringValue = String(format: "✓ Voice learned (%.0f s of speech). From the next session on, you are \"me\".", speech)
            status?.textColor = .systemGreen
            startButton?.isEnabled = false
            let c = completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.close() }
            c?(.success(speech))
        case nil:
            close()
        }
    }

    private func close() {
        panel?.close()
        panel = nil; status = nil; meter = nil; startButton = nil
        running = false; completion = nil
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
