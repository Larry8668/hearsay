import Foundation

// =================================================================================================
// INTEGRATION STUBS — delete this file once Wiring.swift returns the real MicCapture /
// SystemAudioTap / ParakeetEngine. They exist so the whole app (menu, live panel, transcript files)
// runs end to end without audio permissions or a model download.
// Set HEARSAY_FAKE_DENY=me (or them) to simulate a permission denial for that source.
// =================================================================================================

/// Emits 100 ms chunks of near-silence on a timer, timestamped back to back with no gaps.
final class FakeSource: AudioSource {
    let speaker: Speaker
    var displayName: String { speaker == .me ? "Fake microphone" : "Fake system audio" }
    private var timer: DispatchSourceTimer?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private let queue = DispatchQueue(label: "hearsay.fake-source")

    init(speaker: Speaker) { self.speaker = speaker }

    func start() throws -> AsyncStream<AudioChunk> {
        if ProcessInfo.processInfo.environment["HEARSAY_FAKE_DENY"] == speaker.rawValue {
            throw AudioSourceError.permissionDenied(speaker)
        }
        stop()
        let (stream, cont) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(100))
        continuation = cont
        let speaker = self.speaker
        let origin = Date()
        var n = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler {
            let samples = (0..<1600).map { _ in Float.random(in: -0.002...0.002) }
            var chunk = AudioChunk(samples: samples, startTime: origin.addingTimeInterval(Double(n) * 0.1), speaker: speaker)
            if speaker == .them { chunk.sourceApps = ["us.zoom.xos"] }
            n += 1
            cont.yield(chunk)
        }
        t.resume()
        timer = t
        Log.info("FakeSource(\(speaker)): started")
        return stream
    }

    func stop() {
        timer?.cancel(); timer = nil
        continuation?.finish(); continuation = nil
    }
}

/// Every few seconds "hears" a canned sentence: a few growing partials, then a final line whose
/// start/end come from the fed chunk timestamps (so them/me lines interleave and sometimes arrive
/// out of order, like the real engines).
actor FakeEngine: TranscriptionEngine {
    nonisolated let identifier = "fake-stub"
    nonisolated let displayName = "Fake engine (integration stub)"
    nonisolated let languages = ["en"]

    private static let me = [
        "So the deadline moves to Friday?", "I can take the first pass at the slides.",
        "Let me check the numbers and get back to you.", "Sounds good, let's keep it short.",
        "Could you share the link in the chat?", "I think we should ship the smaller version first.",
    ]
    private static let them = [
        "Yes, and we'll need the deck a day earlier.", "The client asked about pricing again.",
        "I'll send the summary after the call.", "Can everyone see my screen?",
        "We're still waiting on legal for the contract.", "Let's sync again on Thursday morning.",
    ]

    private var continuation: AsyncStream<EngineEvent>.Continuation?
    private var loop: Task<Void, Never>?
    private var lastChunkEnd: Date?
    private var lastApps: [String] = []
    private static let prepared = Flag()

    func prepare(progress: @escaping @Sendable (ModelState) -> Void) async throws {
        // Simulate a first-run model download (~3 s) once per process, so the UI can be exercised.
        if Self.prepared.testAndSet() { progress(.ready); return }
        progress(.notDownloaded)
        for i in 0...20 {
            progress(.downloading(fraction: Double(i) / 20))
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        progress(.ready)
    }

    func start(speaker: Speaker) async throws -> AsyncStream<EngineEvent> {
        let (stream, cont) = AsyncStream.makeStream(of: EngineEvent.self)
        continuation = cont
        lastChunkEnd = nil
        let script = speaker == .me ? Self.me : Self.them
        loop = Task { [weak self] in
            var i = speaker == .me ? 0 : 3
            // Offset the two speakers so their utterances overlap.
            try? await Task.sleep(nanoseconds: speaker == .me ? 1_000_000_000 : 2_500_000_000)
            while !Task.isCancelled {
                guard let self = self else { return }
                let text = script[i % script.count]; i += 1
                let start = await self.now()
                let words = text.split(separator: " ")
                for k in 1...words.count {
                    if Task.isCancelled { return }
                    cont.yield(.partial(text: words.prefix(k).joined(separator: " "), speaker: speaker))
                    try? await Task.sleep(nanoseconds: 280_000_000)
                }
                let end = await self.now()
                // "them" commits late (as a slower engine would), so a later "me" line often
                // lands first — exercises the store's sorted insert.
                if speaker == .them { try? await Task.sleep(nanoseconds: 1_200_000_000) }
                let app = await self.app()
                cont.yield(.final(TranscriptLine(speaker: speaker, sourceApp: speaker == .them ? app : nil,
                                                 start: start, end: end, text: text, engine: self.identifier)))
                if i % 5 == 0 { cont.yield(.warning("Fake engine: simulated hiccup (\(speaker.rawValue))")) }
                try? await Task.sleep(nanoseconds: UInt64.random(in: 1_500_000_000...3_500_000_000))
            }
        }
        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        lastChunkEnd = chunk.endTime
        if !chunk.sourceApps.isEmpty { lastApps = chunk.sourceApps }
    }

    func stop() async {
        loop?.cancel(); loop = nil
        continuation?.finish(); continuation = nil
    }

    private func now() -> Date { lastChunkEnd ?? Date() }
    private func app() -> String? { lastApps.first ?? "us.zoom.xos" }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func testAndSet() -> Bool { lock.lock(); defer { lock.unlock() }; let v = value; value = true; return v }
    }
}
