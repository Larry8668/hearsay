import XCTest
@testable import hearsay

/// The main window's sidebar reads `.json` sidecars (`TranscriptLibrary.parse`), and the speaker
/// toggles filter what the window shows, copies and exports, never what is saved.
final class TranscriptLibraryTests: XCTestCase {
    /// 2026-11-09 14:03:00 UTC.
    let t0 = Date(timeIntervalSince1970: 1_794_232_980)
    let utc = TimeZone(identifier: "UTC")!
    let names = ["us.zoom.xos": "Zoom", "com.apple.Safari": "Safari"]
    var fmt: TranscriptFormatter { TranscriptFormatter(timeZone: utc, appName: { [names] in names[$0] ?? $0 }) }
    var tmp: URL!

    override func setUp() { tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hearsay-library-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func line(_ s: Speaker, _ offset: TimeInterval, _ text: String, app: String? = nil) -> TranscriptLine {
        TranscriptLine(speaker: s, sourceApp: app, start: t0.addingTimeInterval(offset),
                       end: t0.addingTimeInterval(offset + 2), text: text, engine: "test-engine")
    }

    let zoom = Voice(speaker: .them, app: "us.zoom.xos"), safari = Voice(speaker: .them, app: "com.apple.Safari")

    /// A finished store with me, Zoom and Safari lines and one 4-minute pause.
    func makeStore() -> TranscriptStore {
        let store = TranscriptStore(directory: tmp, startedAt: t0, engine: "test-engine", formatter: fmt, debounce: 0)
        store.insert(line(.me, 10, "Hello from me"))
        store.insert(line(.them, 12, "Zoom says hi", app: "us.zoom.xos"))
        store.beginPause(at: t0.addingTimeInterval(60))
        store.endPause(at: t0.addingTimeInterval(300))
        store.insert(line(.them, 400, "Safari plays a video", app: "com.apple.Safari"))
        store.insert(line(.me, 410, "Me again"))
        store.finish(at: t0.addingTimeInterval(38 * 60))
        return store
    }

    // MARK: Parsing sidecars

    func testParseSidecarSummary() throws {
        let store = makeStore()
        let entry = try XCTUnwrap(TranscriptLibrary.parse(Data(contentsOf: store.jsonURL), url: store.jsonURL, appName: { self.names[$0] ?? $0 }))
        XCTAssertEqual(entry.jsonURL, store.jsonURL)
        XCTAssertEqual(entry.markdownURL, store.markdownURL)
        XCTAssertEqual(entry.startedAt.timeIntervalSince1970, t0.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(entry.duration, 38 * 60, accuracy: 0.01)
        XCTAssertEqual(entry.lineCount, 4)
        XCTAssertEqual(entry.apps, ["Zoom", "Safari"])   // order of first appearance
        XCTAssertEqual(entry.engine, "test-engine")
        XCTAssertEqual(entry.pausedTotal, 240, accuracy: 0.01)
    }

    func testUnfinishedSidecarEndsWithItsLastLine() throws {
        let store = TranscriptStore(directory: tmp, startedAt: t0, engine: "e", formatter: fmt, debounce: 0)
        store.insert(line(.me, 10, "only line"))
        store.waitForWrites()
        let entry = try XCTUnwrap(TranscriptLibrary.parse(Data(contentsOf: store.jsonURL), url: store.jsonURL))
        XCTAssertNil(entry.endedAt)
        XCTAssertEqual(entry.duration, 12, accuracy: 0.01)
        XCTAssertEqual(entry.apps, [])
    }

    func testNotASidecarIsSkipped() {
        XCTAssertNil(TranscriptLibrary.parse(Data("{\"foo\": 1}".utf8), url: tmp.appendingPathComponent("x.json")))
        XCTAssertNil(TranscriptLibrary.parse(Data("not json".utf8), url: tmp.appendingPathComponent("x.json")))
    }

    func testLoadReturnsLinesAndPauses() throws {
        let store = makeStore()
        let doc = try XCTUnwrap(TranscriptLibrary.load(store.jsonURL, appName: { self.names[$0] ?? $0 }))
        XCTAssertEqual(doc.lines.map(\.text), ["Hello from me", "Zoom says hi", "Safari plays a video", "Me again"])
        XCTAssertEqual(doc.pauses.count, 1)
        XCTAssertEqual(doc.entry.lineCount, 4)
        XCTAssertEqual(doc.lines.voices, [.me, safari, zoom])   // me first, then apps by bundle id
    }

    @MainActor
    func testLibraryListsNewestFirstAndIgnoresOtherFiles() throws {
        _ = makeStore()
        let later = TranscriptStore(directory: tmp, startedAt: t0.addingTimeInterval(3600), engine: "e", formatter: fmt, debounce: 0)
        later.insert(line(.me, 5, "later session"))
        later.finish(at: t0.addingTimeInterval(3700))
        try Data("[]".utf8).write(to: tmp.appendingPathComponent("notes.json"))
        try Data("# hi".utf8).write(to: tmp.appendingPathComponent("readme.md"))

        let lib = TranscriptLibrary(directory: tmp)
        let loaded = expectation(description: "entries")
        let sub = lib.$entries.dropFirst().sink { if $0.count == 2 { loaded.fulfill() } }
        lib.start()
        wait(for: [loaded], timeout: 5)
        _ = sub
        XCTAssertEqual(lib.entries.map(\.lineCount), [1, 4])
        XCTAssertEqual(lib.entries[0].jsonURL, later.jsonURL)
    }

    // MARK: Voice filter: view, Copy, SRT — never the files

    func testVisibleHidesVoicesButFilesKeepEveryLine() throws {
        let store = makeStore()
        let shown = store.lines.visible(hiding: [zoom])
        XCTAssertEqual(shown.map(\.text), ["Hello from me", "Safari plays a video", "Me again"])
        XCTAssertEqual(store.lines.visible(hiding: []).count, 4)
        XCTAssertEqual(store.lines.visible(hiding: [.me, zoom, safari]), [])

        // Copy of the view: hidden voice gone.
        let text = store.plainText(hiding: [zoom, safari])
        XCTAssertEqual(text, "[14:03:10] me: Hello from me\n[14:09:50] me: Me again")

        // SRT of the view: hidden voice gone, cues renumbered from 1, times still from the session start.
        let srt = try XCTUnwrap(store.exportSRT(hiding: [.me]))
        let srtText = try String(contentsOf: srt, encoding: .utf8)
        XCTAssertEqual(srtText, """
        1
        00:00:12,000 --> 00:00:14,000
        them (Zoom): Zoom says hi

        2
        00:06:40,000 --> 00:06:42,000
        them (Safari): Safari plays a video


        """)

        // The saved files are untouched by any of that.
        let md = try String(contentsOf: store.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("Zoom says hi") && md.contains("Hello from me") && md.contains("Me again"))
        let side = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(contentsOf: store.jsonURL))
        XCTAssertEqual(side.lines.count, 4)
    }

    func testWriteSRTForASavedTranscriptHonoursTheFilter() throws {
        let store = makeStore()
        let doc = try XCTUnwrap(TranscriptLibrary.load(store.jsonURL))
        let url = try XCTUnwrap(TranscriptStore.writeSRT(lines: doc.lines.visible(hiding: [zoom, safari]), start: doc.entry.startedAt,
                                                         nextTo: doc.entry.markdownURL, formatter: fmt))
        XCTAssertEqual(url, doc.entry.srtURL)
        let srt = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(srt.contains("me: Hello from me") && srt.contains("me: Me again"))
        XCTAssertFalse(srt.contains("Zoom") || srt.contains("Safari"))
        XCTAssertNil(TranscriptStore.writeSRT(lines: [], start: t0, nextTo: doc.entry.markdownURL), "nothing to export")
    }

    @MainActor
    func testHiddenVoicesAlsoFilterPartials() {
        let model = AppModel()
        model.partials = [.me: "typing", zoom: "zoom partial"]
        model.hiddenVoices = [zoom]
        XCTAssertEqual(model.partials.filter { !model.hiddenVoices.contains($0.key) }, [.me: "typing"])
    }
}

/// Bulk delete: one trash call for every file of every given transcript, never the live one's.
final class TranscriptLibraryBulkDeleteTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hearsay-bulk-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func entry(_ name: String, srt: Bool = false) throws -> TranscriptLibrary.Entry {
        let json = tmp.appendingPathComponent(name + ".json")
        try Data("{}".utf8).write(to: json)
        try Data("md".utf8).write(to: json.deletingPathExtension().appendingPathExtension("md"))
        if srt { try Data("srt".utf8).write(to: json.deletingPathExtension().appendingPathExtension("srt")) }
        return TranscriptLibrary.Entry(jsonURL: json, startedAt: Date(), endedAt: nil, engine: "e", lineCount: 1, apps: [],
                                       pausedTotal: 0, lastLineEnd: Date())
    }

    func testFilesToTrashSkipsLiveAndMissingFiles() throws {
        let a = try entry("a-\(UUID().uuidString)", srt: true), b = try entry("b-\(UUID().uuidString)"), live = try entry("live-\(UUID().uuidString)")
        let urls = TranscriptLibrary.filesToTrash([a, live, b], except: live.jsonURL)
        XCTAssertEqual(Set(urls), [a.jsonURL, a.markdownURL, a.srtURL, b.jsonURL, b.markdownURL])
    }

    @MainActor func testBulkDeleteMovesAllFilesAndKeepsLive() throws {
        let a = try entry("hearsay-test-a-\(UUID().uuidString)", srt: true), b = try entry("hearsay-test-b-\(UUID().uuidString)")
        let live = try entry("hearsay-test-live-\(UUID().uuidString)")
        let done = expectation(description: "recycled")
        var moved: [URL: URL] = [:]
        TranscriptLibrary(directory: tmp).delete([a, b, live], except: live.jsonURL) { moved = $0; done.fulfill() }
        wait(for: [done], timeout: 20)
        defer { for t in moved.values { try? FileManager.default.removeItem(at: t) } }   // don't litter the user's Trash
        let fm = FileManager.default
        for u in [a.jsonURL, a.markdownURL, a.srtURL, b.jsonURL, b.markdownURL] { XCTAssertFalse(fm.fileExists(atPath: u.path), u.lastPathComponent) }
        XCTAssertEqual(moved.count, 5)
        XCTAssertTrue(fm.fileExists(atPath: live.jsonURL.path))
        XCTAssertTrue(fm.fileExists(atPath: live.markdownURL.path))
    }
}
