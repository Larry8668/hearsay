import XCTest
@testable import hearsay

final class EchoFilterTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testDegradedCopyOfThemLineIsEcho() {
        var f = EchoFilter()
        f.observeThem(text: "The quarterly numbers look strong, but we need to move the deadline to Friday.",
                      start: t0, end: t0.addingTimeInterval(4))
        XCTAssertTrue(f.isEcho(text: "quarterly numbers looks strong we need move deadline Friday",
                               start: t0.addingTimeInterval(1), end: t0.addingTimeInterval(5)))
    }

    func testUnrelatedSpeechAtTheSameTimeIsKept() {
        var f = EchoFilter()
        f.observeThem(text: "The quarterly numbers look strong, but we need to move the deadline to Friday.",
                      start: t0, end: t0.addingTimeInterval(4))
        XCTAssertFalse(f.isEcho(text: "Can you hear me okay? My camera is frozen again.",
                                start: t0.addingTimeInterval(1), end: t0.addingTimeInterval(4)))
    }

    func testSameWordsFarApartInTimeAreNotEcho() {
        var f = EchoFilter()
        f.observeThem(text: "move the deadline to Friday and send the deck", start: t0, end: t0.addingTimeInterval(3))
        XCTAssertFalse(f.isEcho(text: "move the deadline to Friday and send the deck",
                                start: t0.addingTimeInterval(30), end: t0.addingTimeInterval(33)))
    }

    func testShortLinesAreNeverDropped() {
        var f = EchoFilter()
        f.observeThem(text: "yes okay sure", start: t0, end: t0.addingTimeInterval(1))
        XCTAssertFalse(f.isEcho(text: "yes okay", start: t0, end: t0.addingTimeInterval(1)))
    }
}
