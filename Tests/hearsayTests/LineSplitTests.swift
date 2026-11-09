import XCTest
@testable import hearsay

/// Mid-speech line cuts (sentence / clause), driven by a fake model transcript and a loud tone so
/// the silence rule never fires.
final class LineSplitTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 20_000)
    var fed = 0
    var config = UtteranceTracker.Config(modelLatency: 0.5)

    func feed(_ t: inout UtteranceTracker, seconds: Double, loud: Bool = true) {
        for _ in 0..<Int((seconds * 10).rounded()) {
            let base = fed
            let samples = (0..<1600).map { i in loud ? 0.2 * sin(Float(base + i) * 2 * .pi * 440 / 16_000) : 0 }
            t.ingest(AudioChunk(samples: samples, startTime: t0.addingTimeInterval(Double(fed) / 16_000), speaker: .them))
            fed += 1600
        }
    }
    func secs(_ d: Date) -> Double { d.timeIntervalSince(t0) }

    /// Rule (b): a 7 s old line is cut at its last sentence end; the rest stays pending.
    func testSentenceCutAfterSevenSeconds() {
        var t = UtteranceTracker(config: config)
        t.update(transcript: "The basic idea is simple.")
        feed(&t, seconds: 3)
        t.update(transcript: "The basic idea is simple. Audio arrives in small chunks, and the model")
        feed(&t, seconds: 3.5)
        t.update(transcript: "The basic idea is simple. Audio arrives in small chunks, and the model updates. It keeps")
        XCTAssertNil(t.finalReason(modelSignalledEnd: false), "6.5 s: too young to cut")
        feed(&t, seconds: 0.5)
        XCTAssertEqual(t.finalReason(modelSignalledEnd: false), .sentence)
        let full = t.hypothesis
        let line = t.commit(reason: .sentence, speaker: .them, engine: "x", modelWillReset: false)!
        // "updates. It" appeared only 0.5 s ago: not stable yet, so the cut is at "simple. Audio".
        XCTAssertEqual(line.text, "The basic idea is simple.")
        XCTAssertEqual(t.pending, "Audio arrives in small chunks, and the model updates. It keeps")
        XCTAssertEqual(line.text + " " + t.pending, full, "no word lost or repeated")
        // "simple." first appeared at 0 s; minus 0.5 s latency, clamped into the line.
        XCTAssertEqual(secs(line.start), 0, accuracy: 0.001)
        XCTAssertGreaterThan(line.end, line.start)

        // The model keeps going; the remainder becomes its own line, starting where the first ended.
        t.update(transcript: full + " going and going.")
        feed(&t, seconds: 2)
        feed(&t, seconds: 1.3, loud: false)
        XCTAssertEqual(t.finalReason(modelSignalledEnd: false), .silence)
        let rest = t.commit(reason: .silence, speaker: .them, engine: "x", modelWillReset: true)!
        XCTAssertEqual(rest.text, "Audio arrives in small chunks, and the model updates. It keeps going and going.")
        XCTAssertEqual(rest.start, line.end, "remainder starts at the split point")
    }

    func testCutTimeComesFromWhenTheTextAppeared() {
        var t = UtteranceTracker(config: config)
        feed(&t, seconds: 1)
        t.update(transcript: "One two three.")
        feed(&t, seconds: 3)
        t.update(transcript: "One two three. Four five six seven")
        feed(&t, seconds: 4)
        let line = t.commit(reason: .sentence, speaker: .me, engine: "x", modelWillReset: false)!
        XCTAssertEqual(line.text, "One two three.")
        XCTAssertEqual(secs(line.end), 0.5, accuracy: 0.001, "seen at 1 s, minus 0.5 s latency")
        XCTAssertEqual(t.pending, "Four five six seven")
    }

    func testAbbreviationsAndLowercaseAreNotSentenceEnds() {
        XCTAssertFalse(LineSplitter.endsSentence("Mr."))
        XCTAssertFalse(LineSplitter.endsSentence("e.g."))
        XCTAssertFalse(LineSplitter.endsSentence("U.S."))
        XCTAssertTrue(LineSplitter.endsSentence("done."))
        XCTAssertTrue(LineSplitter.endsSentence("really?\""))
        XCTAssertTrue(LineSplitter.startsSentence("\"Okay"))
        XCTAssertFalse(LineSplitter.startsSentence("okay"))

        var t = UtteranceTracker(config: config)
        t.update(transcript: "We met Mr. Smith and the team at the U.S. office in the morning")
        feed(&t, seconds: 8)
        XCTAssertNil(t.splitPoint())
    }

    /// Rule (c): 40 words without a sentence end are cut at the last clause boundary.
    func testClauseCutAtFortyWords() {
        var t = UtteranceTracker(config: config)
        let first = (1...20).map { "w\($0)" }.joined(separator: " ") + ","
        let second = (21...42).map { "w\($0)" }.joined(separator: " ")
        t.update(transcript: first + " " + second)
        feed(&t, seconds: 1.5)
        XCTAssertEqual(t.finalReason(modelSignalledEnd: false), .clause)
        let line = t.commit(reason: .clause, speaker: .them, engine: "x", modelWillReset: false)!
        XCTAssertEqual(line.text, first)
        XCTAssertEqual(t.pending, second)
        XCTAssertNil(t.finalReason(modelSignalledEnd: false), "22 words left, 1.5 s old")
    }

    /// Rule (c) without any punctuation: 12 s in, cut at a word boundary (before a conjunction).
    func testRunOnCutAtWordBoundaryAfterTwelveSeconds() {
        var t = UtteranceTracker(config: config)
        var text = "so we started"
        t.update(transcript: text)
        for i in 1...11 {
            feed(&t, seconds: 1)
            text += " and then w\(i)"
            t.update(transcript: text)
            if i < 11 { XCTAssertNil(t.finalReason(modelSignalledEnd: false), "\(i) s") }
        }
        feed(&t, seconds: 1)
        XCTAssertEqual(t.finalReason(modelSignalledEnd: false), .clause)
        let line = t.commit(reason: .clause, speaker: .them, engine: "x", modelWillReset: false)!
        // No commas: cut before the last stable conjunction.
        XCTAssertTrue(line.text.hasSuffix("and then w10"), line.text)
        XCTAssertEqual(line.text + " " + t.pending, text)
        XCTAssertEqual(t.pending, "and then w11")
    }

    /// The model revises committed text ("simple." → "simple:"): the next line must neither repeat
    /// nor drop words.
    func testRevisionOfCommittedTextIsRealigned() {
        var t = UtteranceTracker(config: config)
        t.update(transcript: "The idea is simple. Audio arrives in chunks")
        feed(&t, seconds: 8)
        let line = t.commit(reason: .sentence, speaker: .them, engine: "x", modelWillReset: false)!
        XCTAssertEqual(line.text, "The idea is simple.")
        t.update(transcript: "The idea is simple: audio arrives in chunks and the model")
        XCTAssertEqual(t.pending, "audio arrives in chunks and the model")
        XCTAssertEqual(t.realignments, 1)
    }

    func testUnpunctuatedRunOnWithoutConjunctionCutsAtLastStableWord() {
        var t = UtteranceTracker(config: config)
        let text = (1...41).map { "w\($0)" }.joined(separator: " ")
        t.update(transcript: text)
        feed(&t, seconds: 1.5)
        let line = t.commit(reason: .clause, speaker: .them, engine: "x", modelWillReset: false)!
        XCTAssertEqual(t.pending, "w41")
        XCTAssertEqual(line.text + " " + t.pending, text)
    }

    func testTextAgesTrackRevisions() {
        var a = TextAges()
        a.update(stable: 0, newCount: 10, at: 100)
        a.update(stable: 10, newCount: 20, at: 200)
        a.update(stable: 15, newCount: 25, at: 300)   // bytes 15..<20 revised
        XCTAssertEqual(a.firstSeen(5, fallback: -1), 100)
        XCTAssertEqual(a.firstSeen(12, fallback: -1), 200)
        XCTAssertEqual(a.firstSeen(17, fallback: -1), 300)
        XCTAssertEqual(a.firstSeen(30, fallback: -1), -1)
    }
}
