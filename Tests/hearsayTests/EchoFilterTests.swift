import XCTest
@testable import hearsay

final class EchoFilterTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    let video = "On top of the prediction, the decoder keeps a short memory of what it said before. However, the quarterly numbers look strong."

    func testDegradedCopyOfThemLineIsEcho() {
        var f = EchoFilter()
        f.observeThemFinal(text: "The quarterly numbers look strong, but we need to move the deadline to Friday.", start: t0, end: at(4))
        XCTAssertNotEqual(f.checkMeFinal(text: "quarterly numbers looks strong we need move deadline Friday",
                                         start: at(1), end: at(5), levelGap: nil), .keep)
    }

    /// The user's report: the video's whole passage on the me-lane at the same second. Its partials
    /// are hidden as they arrive, and the final is dropped.
    func testFullEchoPartialsHiddenAndFinalDropped() {
        var f = EchoFilter()
        f.observeThemPartial(text: "On top of the prediction, the decoder keeps", now: at(3))
        XCTAssertTrue(f.checkMePartial(text: "On top of the prediction partic", now: at(3.5)))
        f.observeThemPartial(text: "On top of the prediction, the decoder keeps a short memory of what it said before.", now: at(6))
        XCTAssertTrue(f.checkMePartial(text: "On top of the prediction the decoder keeps a short memory", now: at(6.2)))
        f.observeThemFinal(text: video, start: at(0), end: at(9))
        XCTAssertNotEqual(f.checkMeFinal(text: "On top of the prediction the decoder keeps a short memory of what it said",
                                         start: at(1), end: at(8), levelGap: nil), .keep)
    }

    /// A me-partial that starts genuine and then picks up echo is hidden thanks to the tail check.
    func testEchoTailOfPartialIsCaught() {
        var f = EchoFilter()
        f.observeThemPartial(text: video, now: at(9))
        XCTAssertTrue(f.checkMePartial(
            text: "Let me just check my calendar for Thursday afternoon decoder keeps short memory what said before", now: at(9)))
    }

    /// AEC residue: one or two words of the video, at the same moment.
    func testFragmentEchoIsDropped() {
        var f = EchoFilter()
        f.observeThemPartial(text: "However, the quarterly numbers", now: at(10))
        XCTAssertTrue(f.checkMePartial(text: "However", now: at(10.3)))
        f.observeThemFinal(text: video, start: at(2), end: at(11))
        XCTAssertNotEqual(f.checkMeFinal(text: "However.", start: at(10), end: at(10.6), levelGap: nil), .keep)
        XCTAssertNotEqual(f.checkMeFinal(text: "quarterly numbers", start: at(10.5), end: at(11.2), levelGap: 30), .keep)
    }

    /// A short reply that happens to share a word, spoken as loud as the call, is the user talking.
    func testShortReplyAsLoudAsThemIsKept() {
        var f = EchoFilter()
        f.observeThemFinal(text: "Does Friday work for you?", start: at(0), end: at(2))
        XCTAssertEqual(f.checkMeFinal(text: "Friday works.", start: at(2.5), end: at(3), levelGap: 2), .keep)
        XCTAssertEqual(f.checkMeFinal(text: "Sounds good.", start: at(2.5), end: at(3), levelGap: nil), .keep)
    }

    /// Genuine crosstalk: talking over them about something else is never dropped, whatever the levels.
    func testGenuineCrosstalkIsKept() {
        var f = EchoFilter()
        f.observeThemPartial(text: "The quarterly numbers look strong, but we need to move the deadline", now: at(3))
        XCTAssertFalse(f.checkMePartial(text: "Can you hear me? My camera", now: at(3)))
        f.observeThemFinal(text: "The quarterly numbers look strong, but we need to move the deadline to Friday.", start: t0, end: at(4))
        XCTAssertFalse(f.checkMePartial(text: "Can you hear me? My camera froze", now: at(4)))
        XCTAssertEqual(f.checkMeFinal(text: "Can you hear me? My camera froze.", start: at(1), end: at(4), levelGap: 40), .keep)
    }

    /// Levels break ties: 30–50% overlap is echo only when the mic was much quieter than them.
    func testLevelsBreakTiesButNeverBelowMinimumOverlap() {
        var f = EchoFilter()
        f.observeThemFinal(text: "the decoder keeps a short memory of the stream", start: t0, end: at(4))
        // 2 of 5 content words match (40%).
        let mine = "decoder memory looks fine today"
        XCTAssertEqual(f.checkMeFinal(text: mine, start: at(1), end: at(4), levelGap: 3), .keep)
        XCTAssertNotEqual(f.checkMeFinal(text: mine, start: at(1), end: at(4), levelGap: 20), .keep)
        // 1 of 5 (20%): kept even 40 dB down.
        XCTAssertEqual(f.checkMeFinal(text: "decoder sounds fine today thanks", start: at(1), end: at(4), levelGap: 40), .keep)
    }

    /// Most partials were echo and the final still overlaps ≥ 30%: dropped.
    func testMajorityOfEchoPartialsDropsTheFinal() {
        var f = EchoFilter()
        f.observeThemPartial(text: "the decoder keeps a short memory", now: at(2))
        XCTAssertTrue(f.checkMePartial(text: "decoder keeps", now: at(2)))
        XCTAssertTrue(f.checkMePartial(text: "decoder keeps short", now: at(2.2)))
        XCTAssertFalse(f.checkMePartial(text: "decoder keeps short wow nice great job", now: at(2.4)))
        // 3 of 7 match (43%), 2 of 3 partials were echo.
        XCTAssertNotEqual(f.checkMeFinal(text: "decoder keeps short wow nice great stuff", start: at(1), end: at(3), levelGap: nil), .keep)
        // The tally resets per line.
        XCTAssertEqual(f.checkMeFinal(text: "decoder keeps short wow nice great stuff", start: at(1), end: at(3), levelGap: nil), .keep)
    }

    func testSameWordsFarApartInTimeAreNotEcho() {
        var f = EchoFilter()
        f.observeThemFinal(text: "move the deadline to Friday and send the deck", start: t0, end: at(3))
        XCTAssertEqual(f.checkMeFinal(text: "move the deadline to Friday and send the deck", start: at(30), end: at(33), levelGap: 30), .keep)
        XCTAssertEqual(f.checkMeFinal(text: "Friday", start: at(30), end: at(31), levelGap: 30), .keep)
        // A partial 40 s later: outside the 30 s pool.
        XCTAssertFalse(f.checkMePartial(text: "move the deadline to Friday", now: at(43)))
    }

    func testThemPartialIsAtMostTwentyFiveSecondsOld() {
        var f = EchoFilter()
        f.observeThemPartial(text: "move the deadline to Friday", now: t0)
        f.observeThemPartial(text: "move the deadline to Friday and send", now: at(40))
        // The partial is treated as spanning 15…40 s, not 0…40 s.
        XCTAssertEqual(f.checkMeFinal(text: "move the deadline to Friday", start: at(5), end: at(8), levelGap: nil), .keep)
        XCTAssertNotEqual(f.checkMeFinal(text: "move the deadline to Friday", start: at(30), end: at(33), levelGap: nil), .keep)
    }
}
