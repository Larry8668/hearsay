import XCTest
@testable import hearsay

/// The recording bar's caption blocks: a block that has shown words stays up through the gaps
/// in the engine's hypothesis, and the idle line never shows between two partials of one
/// utterance.
final class CaptionsFeedTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_794_232_980)
    let session = Date(timeIntervalSince1970: 1_794_232_970)
    var feed: CaptionsFeed!

    override func setUp() { feed = CaptionsFeed(model: AppModel()) }

    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func line(_ sp: Speaker, _ offset: TimeInterval, _ text: String, app: String? = nil) -> TranscriptLine {
        TranscriptLine(speaker: sp, sourceApp: app, start: at(offset), end: at(offset + 2), text: text, engine: "e")
    }

    func testBlockSurvivesAnEmptyHypothesisMidUtterance() {
        feed.update(lines: [], partials: [.me: "Hello"], session: session, now: at(0))
        XCTAssertEqual(feed.blocks.map(\.partial), ["Hello"])
        // The engine's hypothesis goes empty for a beat (or the echo filter withholds it).
        feed.update(lines: [], partials: [:], session: session, now: at(0.3))
        XCTAssertEqual(feed.blocks.map(\.partial), ["Hello"], "the block must keep its last words, not vanish")
        feed.update(lines: [], partials: [.me: ""], session: session, now: at(0.5))
        XCTAssertEqual(feed.blocks.map(\.partial), ["Hello"])
        feed.update(lines: [], partials: [.me: "Hello there"], session: session, now: at(0.7))
        XCTAssertEqual(feed.blocks.map(\.partial), ["Hello there"])
    }

    /// The original flicker: before any line is committed, an update with the same partial (the
    /// 1 s expiry tick, the other lane's event) dropped the block.
    func testUnchangedPartialAndTimerTickKeepTheBlockBeforeAnyLineIsCommitted() {
        feed.update(lines: [], partials: [.me: "Hello"], session: session, now: at(0))
        for i in 1...12 {
            feed.update(lines: [], partials: [.me: "Hello"], session: session, now: at(Double(i) * 0.5))
            XCTAssertEqual(feed.blocks.count, 1, "tick \(i)")
        }
        // Another lane talking must not disturb it either.
        feed.update(lines: [], partials: [.me: "Hello", Voice(speaker: .them, app: "us.zoom.xos"): "hi"], session: session, now: at(7))
        XCTAssertEqual(feed.blocks.map(\.chip), ["me", "them · Zoom"])
    }

    func testHeldWordsAreReplacedByTheCommittedLineAndExpireAfterSilence() {
        feed.update(lines: [], partials: [.me: "Hello there"], session: session, now: at(0))
        feed.update(lines: [], partials: [:], session: session, now: at(0.3))   // hypothesis empty
        let l = line(.me, 0, "Hello there.")
        feed.update(lines: [l], partials: [:], session: session, now: at(1))
        XCTAssertEqual(feed.blocks.map(\.committed), [["Hello there."]])
        XCTAssertEqual(feed.blocks.map(\.partial), [""], "the line replaces the held words; they must not show twice")
        // Silent: the block expires after `silence` seconds, held words or not.
        feed.update(lines: [l], partials: [.me: "and"], session: session, now: at(2))
        feed.update(lines: [l], partials: [:], session: session, now: at(2.4))
        feed.update(lines: [l], partials: [:], session: session, now: at(2 + CaptionsFeed.silence - 0.5))
        XCTAssertEqual(feed.blocks.map(\.partial), ["and"])
        feed.update(lines: [l], partials: [:], session: session, now: at(2 + CaptionsFeed.silence + 0.5))
        XCTAssertTrue(feed.blocks.isEmpty)
    }

    /// Words the echo filter threw away (a "me" line that was the speakers) are not held.
    func testDiscardedWordsAreDroppedAtOnce() {
        feed.update(lines: [], partials: [.me: "sounds good"], session: session, now: at(0))
        feed.update(lines: [], partials: [:], discards: [.me: 1], session: session, now: at(0.3))
        XCTAssertTrue(feed.blocks.isEmpty)
        // A later gap in the hypothesis still holds (the count is unchanged).
        feed.update(lines: [], partials: [.me: "No, really"], discards: [.me: 1], session: session, now: at(1))
        feed.update(lines: [], partials: [:], discards: [.me: 1], session: session, now: at(1.3))
        XCTAssertEqual(feed.blocks.map(\.partial), ["No, really"])
    }

    func testNewSessionStartsClean() {
        feed.update(lines: [], partials: [.me: "Hello"], session: session, now: at(0))
        feed.update(lines: [], partials: [:], session: session, now: at(0.3))
        XCTAssertEqual(feed.blocks.count, 1)
        feed.update(lines: [], partials: [:], session: at(30), now: at(30))
        XCTAssertTrue(feed.blocks.isEmpty, "a new session must not show the last one's words")
    }

    func testThemPartialMovesUnderItsAppWithoutALeftoverBlock() {
        let unlabelled = Voice(speaker: .them), zoom = Voice(speaker: .them, app: "us.zoom.xos")
        feed.update(lines: [], partials: [unlabelled: "sounds"], session: session, now: at(0))
        feed.update(lines: [], partials: [zoom: "sounds good"], session: session, now: at(0.4))
        XCTAssertEqual(feed.blocks.map(\.chip), ["them · Zoom"])
        XCTAssertEqual(feed.blocks.map(\.partial), ["sounds good"])
    }
}
