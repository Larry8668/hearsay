import XCTest
@testable import hearsay

/// Pause bookkeeping: marker lines, header duration, sidecar. Deterministic dates, UTC.
final class PauseTests: XCTestCase {
    /// 2026-11-09 14:03:00 UTC.
    let t0 = Date(timeIntervalSince1970: 1_794_232_980)
    var fmt: TranscriptFormatter { TranscriptFormatter(timeZone: TimeZone(identifier: "UTC")!, appName: { _ in "Zoom" }) }
    var tmp: URL!

    override func setUp() { tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hearsay-pause-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func line(_ s: Speaker, _ offset: TimeInterval, _ text: String) -> TranscriptLine {
        TranscriptLine(speaker: s, sourceApp: s == .them ? "us.zoom.xos" : nil, start: t0.addingTimeInterval(offset),
                       end: t0.addingTimeInterval(offset + 2), text: text, engine: "e")
    }
    func pause(_ a: TimeInterval, _ b: TimeInterval?) -> PauseInterval {
        PauseInterval(start: t0.addingTimeInterval(a), end: b.map { t0.addingTimeInterval($0) })
    }

    func testMarkerSitsBetweenLinesAndHeaderShowsPausedTime() {
        let lines = [line(.me, 10, "Before."), line(.them, 400, "After.")]
        let md = fmt.markdown(lines: lines, start: t0, end: t0.addingTimeInterval(38 * 60), engine: "e",
                              pauses: [pause(60, 60 + 4 * 60)])
        XCTAssertEqual(md, """
        # Call transcript — Mon 9 Nov 2026, 14:03–14:41 (38 min, 4 min paused)
        _Apps heard: Zoom · Engine: e · Made with hearsay, on this Mac._

        **14:03:10 me** Before.

        _— paused 4 min —_

        **14:09:40 them (Zoom)** After.

        """)
    }

    func testShortPausesInSecondsAndSummed() {
        let pauses = [pause(30, 50), pause(100, 120)]
        XCTAssertEqual(fmt.headerRange(start: t0, end: t0.addingTimeInterval(600), pauses: pauses),
                       "Mon 9 Nov 2026, 14:03–14:13 (10 min, 40 s paused)")
        XCTAssertEqual(fmt.pauseMarker(pauses[0]), "\n_— paused 20 s —_\n")
        XCTAssertEqual(fmt.pauseMarker(pause(30, nil)), "\n_— paused —_\n")
        XCTAssertEqual(TranscriptFormatter.shortDuration(75 * 60), "1 h 15 min")
    }

    func testTrailingPauseAndNoPauses() {
        let md = fmt.markdown(lines: [line(.me, 5, "Hi.")], start: t0, end: t0.addingTimeInterval(300), engine: "e",
                              pauses: [pause(120, 300)])
        XCTAssertTrue(md.hasPrefix("# Call transcript — Mon 9 Nov 2026, 14:03–14:08 (5 min, 3 min paused)\n"))
        XCTAssertTrue(md.hasSuffix("**14:03:05 me** Hi.\n\n_— paused 3 min —_\n"))
        XCTAssertFalse(fmt.markdown(lines: [line(.me, 5, "Hi.")], start: t0, end: t0.addingTimeInterval(300), engine: "e").contains("paused"))
    }

    func testStoreRecordsPausesAndFinishClosesOpenPause() throws {
        let store = TranscriptStore(directory: tmp, startedAt: t0, engine: "e", formatter: fmt, debounce: 0)
        store.insert(line(.me, 5, "One."))
        store.beginPause(at: t0.addingTimeInterval(60))
        store.beginPause(at: t0.addingTimeInterval(70))          // ignored: already paused
        XCTAssertTrue(store.isPaused)
        store.endPause(at: t0.addingTimeInterval(180))
        XCTAssertFalse(store.isPaused)
        store.insert(line(.them, 200, "Two."))
        store.beginPause(at: t0.addingTimeInterval(300))
        store.finish(at: t0.addingTimeInterval(420))             // stop while paused
        XCTAssertEqual(store.pauses, [pause(60, 180), pause(300, 420)])

        let md = try String(contentsOf: store.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.hasPrefix("# Call transcript — Mon 9 Nov 2026, 14:03–14:10 (7 min, 4 min paused)\n"), md)
        XCTAssertEqual(md.components(separatedBy: "_— paused 2 min —_").count, 3)
        let side = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(contentsOf: store.jsonURL))
        XCTAssertEqual(side.pauses, [pause(60, 180), pause(300, 420)])
    }

    func testOldSidecarWithoutPausesDecodes() throws {
        let json = #"{"version":1,"startedAt":"2026-11-09T14:03:00.000Z","engine":"e","lines":[]}"#
        let side = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(json.utf8))
        XCTAssertNil(side.pauses)
    }

    func testLevelMapping() {
        XCTAssertEqual(LevelMeter.level(rms: 0), 0)
        XCTAssertEqual(LevelMeter.level(rms: pow(10, -70.0 / 20)), 0)
        XCTAssertEqual(LevelMeter.level(rms: pow(10, -35.0 / 20)), 0.5, accuracy: 0.001)
        XCTAssertEqual(LevelMeter.level(rms: 1), 1)
        XCTAssertEqual(LevelMeter.rms([0.5, -0.5, 0.5, -0.5]), 0.5, accuracy: 1e-6)
    }
}
