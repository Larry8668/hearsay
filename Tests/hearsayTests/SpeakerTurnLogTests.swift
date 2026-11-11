import XCTest
@testable import hearsay

/// The `diarize` log: per-stream turns, revisions, new speakers and a summary, throttled.
final class SpeakerTurnLogTests: XCTestCase {
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        private var clock = Date(timeIntervalSince1970: 1000)
        var lines: [String] { lock.withLock { stored } }
        var now: Date { lock.withLock { clock } }
        func add(_ s: String) { lock.withLock { stored.append(s) } }
        func advance(_ t: TimeInterval) { lock.withLock { clock += t } }
    }

    func testLinesAndSummary() {
        let sink = Sink()
        let origin = Date(timeIntervalSince1970: 0)
        let log = SpeakerTurnLog(stream: "them:app.zen-browser.zen", origin: origin, now: { sink.now }, emit: { sink.add($0) })
        XCTAssertNil(log.summary(), "nothing settled: no summary")
        log.settled(slot: 0, seconds: 10, at: origin.addingTimeInterval(1))
        log.settled(slot: 0, seconds: 2, at: origin.addingTimeInterval(11))
        log.settled(slot: 3, seconds: 0.9, at: origin.addingTimeInterval(74.3))
        log.turn(from: 1, to: 3, at: origin.addingTimeInterval(74.3), held: 0.9)
        log.revised(tentative: 3, settled: 1, at: origin.addingTimeInterval(74.1))
        // A flickery stream: more revisions within the second are counted, not written.
        log.revised(tentative: 2, settled: 1, at: origin.addingTimeInterval(74.5))
        log.revised(tentative: 2, settled: 1, at: origin.addingTimeInterval(74.6))
        sink.advance(1.1)
        log.revised(tentative: 2, settled: 0, at: origin.addingTimeInterval(75.6))
        XCTAssertEqual(sink.lines, [
            "them:app.zen-browser.zen: new speaker #1 settled at 1.0 s",
            "them:app.zen-browser.zen: new speaker #4 settled at 74.3 s",
            "them:app.zen-browser.zen: turn #2→#4 at 74.3 s, held 0.9 s settled",
            "them:app.zen-browser.zen: tentative #4 at 74.1 s settled as #2",
            "them:app.zen-browser.zen: tentative #3 at 75.6 s settled as #1",
        ])
        XCTAssertEqual(log.summary(), "them:app.zen-browser.zen: summary · 2 speakers (#1 12.0 s, #4 0.9 s) · 1 turn · 4 tentative revisions (2 not logged)")
    }
}

final class DiarizerKindTests: XCTestCase {
    func testTheChoiceTheMenuOffers() {
        XCTAssertEqual(DiarizerKind.offered, [.sortformer, .lseend])
        XCTAssertEqual(DiarizerKind.sortformer.menuTitle, "Steady, up to 4 speakers (Sortformer, 234 MB)")
        XCTAssertEqual(DiarizerKind.lseend.menuTitle, "More speakers, up to 10 (LS-EEND, 43 MB)")
        XCTAssertEqual(DiarizerKind.sortformer.maxSpeakers, 4)
        XCTAssertEqual(DiarizerKind.lseend.maxSpeakers, 10)
        XCTAssertGreaterThan(DiarizerKind.sortformer.downloadSize, DiarizerKind.lseend.downloadSize)
        let suite = "hearsay-tests-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: suite) else { return XCTFail("no defaults suite") }
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DiarizerKind.configured(d), .sortformer)
        d.set("lseend", forKey: DiarizerKind.key)
        XCTAssertEqual(DiarizerKind.configured(d), .lseend)
        d.set("nonsense", forKey: DiarizerKind.key)
        XCTAssertEqual(DiarizerKind.configured(d), .sortformer)
    }

    /// Mid-session the switch waits for the session to end (a new model would renumber everyone).
    func testSwitchingDuringASessionWaitsForItsEnd() async {
        let r = DiarizerRegistry()
        await r.configure(mode: .off, kind: .sortformer)
        let switched = await r.setKind(.lseend, sessionRunning: true)
        XCTAssertFalse(switched)
        let during = await r.kind
        XCTAssertEqual(during, .sortformer)
        let applied = await r.applyPendingKind()
        XCTAssertEqual(applied, .lseend)
        let after = await r.kind
        XCTAssertEqual(after, .lseend)
        let none = await r.applyPendingKind()
        XCTAssertNil(none)
        let now = await r.setKind(.sortformer, sessionRunning: false)
        XCTAssertTrue(now)
    }
}
