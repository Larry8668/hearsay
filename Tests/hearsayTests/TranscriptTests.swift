import XCTest
@testable import hearsay

final class TranscriptTests: XCTestCase {
    /// 2026-11-09 14:03:00 UTC. All tests format in UTC so they don't depend on the machine's zone.
    let t0 = Date(timeIntervalSince1970: 1_794_232_980)
    let utc = TimeZone(identifier: "UTC")!
    var fmt: TranscriptFormatter {
        TranscriptFormatter(timeZone: utc, appName: { ["us.zoom.xos": "Zoom", "com.apple.Safari": "Safari"][$0] ?? $0 })
    }

    func line(_ s: Speaker, _ offset: TimeInterval, _ text: String, app: String? = nil, dur: TimeInterval = 2) -> TranscriptLine {
        TranscriptLine(speaker: s, sourceApp: app, start: t0.addingTimeInterval(offset),
                       end: t0.addingTimeInterval(offset + dur), text: text, engine: "test-engine")
    }

    var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hearsay-tests-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    // MARK: Ordering

    func testOutOfOrderLinesAreSortedByStart() {
        let store = TranscriptStore(directory: tmp, startedAt: t0, engine: "e", formatter: fmt, debounce: 0)
        // "me" at +15 is committed before the slower "them" engine delivers its +12 line.
        store.insert(line(.me, 10, "first"))
        store.insert(line(.me, 15, "third"))
        store.insert(line(.them, 12, "second", app: "us.zoom.xos"))
        store.insert(line(.them, 20, "fourth", app: "us.zoom.xos"))
        store.insert(line(.me, 1, "zeroth"))
        XCTAssertEqual(store.lines.map(\.text), ["zeroth", "first", "second", "third", "fourth"])
    }

    func testEqualStartsKeepArrivalOrder() {
        let a = line(.me, 5, "a"), b = line(.them, 5, "b"), c = line(.me, 5, "c")
        var lines: [TranscriptLine] = []
        for l in [a, b, c] { lines.insert(l, at: TranscriptStore.insertionIndex(for: l.start, in: lines)) }
        XCTAssertEqual(lines.map(\.text), ["a", "b", "c"])
    }

    func testFilesWrittenAndFinalised() throws {
        let store = TranscriptStore(directory: tmp, startedAt: t0, engine: "test-engine", formatter: fmt, debounce: 0)
        store.insert(line(.me, 15.25, "later"))
        store.insert(line(.them, 12, "earlier", app: "us.zoom.xos"))
        store.finish(at: t0.addingTimeInterval(38 * 60))
        let md = try String(contentsOf: store.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.hasPrefix("# Call transcript — Mon 9 Nov 2026, 14:03–14:41 (38 min)\n"))
        XCTAssertLessThan(md.range(of: "earlier")!.lowerBound, md.range(of: "later")!.lowerBound)

        let side = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(contentsOf: store.jsonURL))
        XCTAssertEqual(side.lines.map(\.text), ["earlier", "later"])
        XCTAssertEqual(side.lines[1].start.timeIntervalSince1970, store.lines[1].start.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(side.engine, "test-engine")
        XCTAssertNotNil(side.endedAt)
    }

    func testEmptySessionLeavesNoFile() {
        let store = TranscriptStore(directory: tmp, startedAt: t0, engine: "e", formatter: fmt)
        store.finish(at: t0.addingTimeInterval(60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.markdownURL.path))
    }

    // MARK: Naming

    func testFileName() {
        XCTAssertEqual(fmt.baseName(for: t0), "2026-11-09 14.03 hearsay")
        let store = TranscriptStore(directory: tmp, startedAt: t0, engine: "e", formatter: fmt)
        XCTAssertEqual(store.markdownURL.lastPathComponent, "2026-11-09 14.03 hearsay.md")
        XCTAssertEqual(store.jsonURL.lastPathComponent, "2026-11-09 14.03 hearsay.json")
    }

    func testFileNameCollisionGetsSuffix() throws {
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data().write(to: tmp.appendingPathComponent("2026-11-09 14.03 hearsay.md"))
        let store = TranscriptStore(directory: tmp, startedAt: t0, engine: "e", formatter: fmt)
        XCTAssertEqual(store.markdownURL.lastPathComponent, "2026-11-09 14.03 hearsay 2.md")
    }

    // MARK: Formatting

    func testMarkdown() {
        let lines = [line(.me, 12, "So the deadline moves to Friday?"),
                     line(.them, 15, "Yes, and we'll need the deck a day earlier.", app: "us.zoom.xos"),
                     line(.them, 20, "Sharing *now*.", app: "com.apple.Safari"),
                     line(.them, 25, "Unknown app.")]
        let md = fmt.markdown(lines: lines, start: t0, end: t0.addingTimeInterval(38 * 60 + 10), engine: "parakeet-eou-120m")
        XCTAssertEqual(md, """
        # Call transcript — Mon 9 Nov 2026, 14:03–14:41 (38 min)
        _Apps heard: Zoom, Safari · Engine: parakeet-eou-120m · Made with hearsay, on this Mac._

        **14:03:12 me** So the deadline moves to Friday?

        **14:03:15 them (Zoom)** Yes, and we'll need the deck a day earlier.

        **14:03:20 them (Safari)** Sharing \\*now\\*.

        **14:03:25 them** Unknown app.

        """)
    }

    func testMarkdownInProgressHeader() {
        let md = fmt.markdown(lines: [], start: t0, end: nil, engine: "e")
        XCTAssertEqual(md, "# Call transcript — Mon 9 Nov 2026, 14:03 – in progress\n_Engine: e · Made with hearsay, on this Mac._\n")
    }

    func testDuration() {
        XCTAssertEqual(TranscriptFormatter.duration(20), "under 1 min")
        XCTAssertEqual(TranscriptFormatter.duration(38 * 60), "38 min")
        XCTAssertEqual(TranscriptFormatter.duration(65 * 60), "1 h 05 min")
    }

    func testSRT() {
        let lines = [line(.me, 12, "Hello.", dur: 1.25),
                     line(.them, 3725.5, "Hi.", app: "us.zoom.xos", dur: 0)]   // zero-length → 0.5 s
        XCTAssertEqual(fmt.srt(lines: lines, start: t0), """
        1
        00:00:12,000 --> 00:00:13,250
        me: Hello.

        2
        01:02:05,500 --> 01:02:06,000
        them (Zoom): Hi.


        """)
    }

    func testPlainText() {
        let lines = [line(.me, 12, "Hello."), line(.them, 15, "Hi.", app: "us.zoom.xos")]
        XCTAssertEqual(fmt.plainText(lines: lines), "[14:03:12] me: Hello.\n[14:03:15] them (Zoom): Hi.")
    }
}
