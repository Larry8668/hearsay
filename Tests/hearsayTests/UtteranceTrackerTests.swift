import XCTest
@testable import hearsay

final class SampleClockTests: XCTestCase {
    func testMapsSamplesWithinAndAcrossChunks() {
        var c = SampleClock()
        let t0 = Date(timeIntervalSince1970: 1_000)
        c.append(startTime: t0, sampleCount: 1600)
        c.append(startTime: t0.addingTimeInterval(0.1), sampleCount: 1600)
        XCTAssertEqual(c.date(at: 0), t0)
        XCTAssertEqual(c.date(at: 800).timeIntervalSince(t0), 0.05, accuracy: 1e-6)
        XCTAssertEqual(c.date(at: 2400).timeIntervalSince(t0), 0.15, accuracy: 1e-6)
        XCTAssertEqual(c.date(at: 3200).timeIntervalSince(t0), 0.2, accuracy: 1e-6)  // end extrapolates
    }

    func testFollowsChunkTimestampsAcrossAGap() {
        // A device restart: the second chunk starts 5 s later than the sample count implies.
        var c = SampleClock()
        let t0 = Date(timeIntervalSince1970: 1_000)
        c.append(startTime: t0, sampleCount: 1600)
        c.append(startTime: t0.addingTimeInterval(5), sampleCount: 1600)
        XCTAssertEqual(c.date(at: 1599).timeIntervalSince(t0), 1599.0 / 16_000, accuracy: 1e-6)
        XCTAssertEqual(c.date(at: 1600).timeIntervalSince(t0), 5, accuracy: 1e-6)
        XCTAssertEqual(c.date(at: 2400).timeIntervalSince(t0), 5.05, accuracy: 1e-6)
    }

    func testPruneKeepsCoveringAnchor() {
        var c = SampleClock()
        let t0 = Date(timeIntervalSince1970: 0)
        for i in 0..<10 { c.append(startTime: t0.addingTimeInterval(Double(i) * 0.1), sampleCount: 1600) }
        c.prune(before: 5000)
        XCTAssertEqual(c.anchorCount, 7)  // anchors at 4800, 6400, ... 14400
        XCTAssertEqual(c.date(at: 5000).timeIntervalSince(t0), 5000.0 / 16_000, accuracy: 1e-6)
    }
}

final class AppVotesTests: XCTestCase {
    func testMajorityAndStableTieBreak() {
        var v = AppVotes()
        XCTAssertNil(v.winner)
        v.add(["us.zoom.xos"]); v.add(["com.apple.Music", "us.zoom.xos"]); v.add(["com.apple.Music"]); v.add([""])
        XCTAssertEqual(v.winner, "us.zoom.xos")  // 2–2 tie: first seen wins
        v.add(["com.apple.Music"])
        XCTAssertEqual(v.winner, "com.apple.Music")
        v.reset()
        XCTAssertNil(v.winner)
    }
}

final class UtteranceTrackerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 10_000)
    var fed = 0

    /// Feeds `seconds` of a 440 Hz tone (loud) or digital silence as 100 ms chunks.
    func feed(_ t: inout UtteranceTracker, seconds: Double, loud: Bool, apps: [String] = []) {
        let n = Int((seconds * 10).rounded())
        for _ in 0..<n {
            let base = fed
            let samples = (0..<1600).map { i in loud ? 0.2 * sin(Float(base + i) * 2 * .pi * 440 / 16_000) : 0 }
            t.ingest(AudioChunk(samples: samples, startTime: t0.addingTimeInterval(Double(fed) / 16_000),
                                speaker: .them, sourceApps: apps))
            fed += 1600
        }
    }

    func testSilenceGapFinalisesWithVoicedBounds() {
        var t = UtteranceTracker(config: .init(silenceGap: 1.2, modelLatency: 0.3))
        feed(&t, seconds: 0.5, loud: false)
        feed(&t, seconds: 2.0, loud: true, apps: ["us.zoom.xos"])
        t.update(transcript: "hello there")
        feed(&t, seconds: 1.1, loud: false, apps: ["com.apple.Music"])
        XCTAssertNil(t.finalReason(modelSignalledEnd: false), "1.1 s < 1.2 s gap")
        feed(&t, seconds: 0.1, loud: false)
        XCTAssertEqual(t.finalReason(modelSignalledEnd: false), .silence)
        let line = t.commit(reason: .silence, speaker: .them, engine: "x", modelWillReset: true)!
        XCTAssertEqual(line.text, "hello there")
        XCTAssertEqual(line.start.timeIntervalSince(t0), 0.5, accuracy: 0.001)
        XCTAssertEqual(line.end.timeIntervalSince(t0), 2.5, accuracy: 0.001)
        XCTAssertEqual(line.sourceApp, "us.zoom.xos", "silent chunks don't vote")
        XCTAssertEqual(line.engine, "x")
        XCTAssertEqual(t.pending, "")
        XCTAssertNil(t.finalReason(modelSignalledEnd: false))
    }

    func testNoFinalWithoutText() {
        var t = UtteranceTracker()
        feed(&t, seconds: 1, loud: true)
        feed(&t, seconds: 5, loud: false)
        XCTAssertNil(t.finalReason(modelSignalledEnd: true))
    }

    func testModelEndOfUtteranceWins() {
        var t = UtteranceTracker()
        feed(&t, seconds: 1, loud: true)
        t.update(transcript: "yes")
        XCTAssertEqual(t.finalReason(modelSignalledEnd: true), .endOfUtterance)
    }

    func testMaxLengthCutsAtWordBoundaryAndKeepsTail() {
        var t = UtteranceTracker(config: .init(maxUtterance: 3, modelLatency: 0.16))
        feed(&t, seconds: 2, loud: true)
        t.update(transcript: "one two thr")
        feed(&t, seconds: 1, loud: true)
        t.update(transcript: "one two three")
        XCTAssertEqual(t.finalReason(modelSignalledEnd: false), .maxLength)
        let line = t.commit(reason: .maxLength, speaker: .me, engine: "x", modelWillReset: false)!
        XCTAssertEqual(line.text, "one two")
        XCTAssertNil(line.sourceApp)
        XCTAssertEqual(t.pending, "three")
        t.update(transcript: "one two three four")
        XCTAssertEqual(t.pending, "three four")
    }

    func testStalledHypothesisFinalisesInNoise() {
        // Constant loud audio (a noisy room) never trips the silence rule; a frozen hypothesis does.
        var t = UtteranceTracker(config: .init(silenceGap: 1.2, maxUtterance: 60, modelLatency: 0.5))
        t.update(transcript: "are you there")
        feed(&t, seconds: 2.6, loud: true)  // stall threshold: max(1.2, 0.8) + 0.5 + 1 = 2.7 s
        XCTAssertNil(t.finalReason(modelSignalledEnd: false))
        feed(&t, seconds: 0.1, loud: true)
        XCTAssertEqual(t.finalReason(modelSignalledEnd: false), .stalled)
    }

    func testLargeChunkTierWaitsForTheModel() {
        // 2.24 s Nemotron chunks: words may still be in the model's buffer 1.2 s after speech ends.
        var t = UtteranceTracker(config: .init(silenceGap: 1.2, modelLatency: 2.24))
        feed(&t, seconds: 1, loud: true)
        t.update(transcript: "hi")
        feed(&t, seconds: 2.5, loud: false)
        XCTAssertNil(t.finalReason(modelSignalledEnd: false))
        feed(&t, seconds: 0.1, loud: false)
        XCTAssertEqual(t.finalReason(modelSignalledEnd: false), .silence)
    }
}
