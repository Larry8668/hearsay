import XCTest
@testable import hearsay

/// Titles, tags and speaker names: how they are stored in the sidecar, how a voice's name
/// resolves, and that every export and the sidebar search respect them.
final class TranscriptMetaTests: XCTestCase {
    /// 2026-11-09 14:03:00 UTC.
    let t0 = Date(timeIntervalSince1970: 1_794_232_980)
    let utc = TimeZone(identifier: "UTC")!
    let appNames = ["us.zoom.xos": "Zoom", "com.apple.Safari": "Safari"]
    var fmt: TranscriptFormatter { TranscriptFormatter(timeZone: utc, appName: { [appNames] in appNames[$0] ?? $0 }) }
    let zoom = Voice(speaker: .them, app: "us.zoom.xos"), safari = Voice(speaker: .them, app: "com.apple.Safari")
    var tmp: URL!

    override func setUp() { tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hearsay-meta-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func line(_ s: Speaker, _ offset: TimeInterval, _ text: String, app: String? = nil) -> TranscriptLine {
        TranscriptLine(speaker: s, sourceApp: app, start: t0.addingTimeInterval(offset),
                       end: t0.addingTimeInterval(offset + 2), text: text, engine: "test-engine")
    }

    var sampleMeta: TranscriptMeta {
        TranscriptMeta(title: "Design review", tags: ["design", "q4"], names: ["me": "Aditya", "them:us.zoom.xos": "Priya"])
    }

    /// me, Zoom and Safari lines; `yourName` fixed so the machine's Settings don't leak in.
    func makeStore(meta: TranscriptMeta = TranscriptMeta(), yourName: String? = nil) -> TranscriptStore {
        let store = TranscriptStore(directory: tmp, startedAt: t0, engine: "test-engine", formatter: fmt, debounce: 0, yourName: { yourName })
        store.meta = meta
        store.insert(line(.me, 10, "Hello from me"))
        store.insert(line(.them, 12, "Zoom says hi", app: "us.zoom.xos"))
        store.insert(line(.them, 400, "Safari plays a video", app: "com.apple.Safari"))
        store.insert(line(.me, 410, "Me again"))
        store.finish(at: t0.addingTimeInterval(38 * 60))
        return store
    }

    // MARK: Voice keys

    func testVoiceKeyIsStableAndRoundTrips() {
        XCTAssertEqual(Voice.me.key, "me")
        XCTAssertEqual(Voice(speaker: .them).key, "them")
        XCTAssertEqual(zoom.key, "them:us.zoom.xos")
        for v in [Voice.me, Voice(speaker: .them), zoom] { XCTAssertEqual(Voice(key: v.key), v) }
        // A later diarization suffix names a person within the voice; the voice still resolves.
        XCTAssertEqual(Voice(key: "me#1"), .me)
        XCTAssertEqual(Voice(key: "them:us.zoom.xos#2"), zoom)
        XCTAssertNil(Voice(key: "robot"))
    }

    // MARK: Sidecar round trip

    func testSidecarKeepsTitleTagsAndNames() throws {
        let store = makeStore(meta: sampleMeta)
        let side = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(contentsOf: store.jsonURL))
        XCTAssertEqual(side.meta, sampleMeta)
        XCTAssertEqual(side.lines.count, 4)
        XCTAssertEqual(side.lines.map(\.speaker), [.me, .them, .them, .me], "lines keep their raw voices; names live in the map")
        XCTAssertEqual(side.version, 1)
        let entry = try XCTUnwrap(TranscriptLibrary.parse(Data(contentsOf: store.jsonURL), url: store.jsonURL))
        XCTAssertEqual(entry.meta, sampleMeta)
        XCTAssertEqual(try XCTUnwrap(TranscriptLibrary.load(store.jsonURL)).meta, sampleMeta)
        // The raw JSON has the three keys at the top level, beside the lines.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.jsonURL)) as? [String: Any])
        XCTAssertEqual(json["title"] as? String, "Design review")
        XCTAssertEqual(json["tags"] as? [String], ["design", "q4"])
        XCTAssertEqual(json["names"] as? [String: String], sampleMeta.names)
    }

    func testOldSidecarWithoutMetaStillLoads() throws {
        let store = makeStore()
        // What 0.2.0 wrote: no title / tags / names keys at all.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.jsonURL)) as? [String: Any])
        XCTAssertNil(json["title"]); XCTAssertNil(json["tags"]); XCTAssertNil(json["names"], "nothing set: nothing written")
        json["title"] = nil; json["tags"] = nil; json["names"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: store.jsonURL)
        let doc = try XCTUnwrap(TranscriptLibrary.load(store.jsonURL))
        XCTAssertEqual(doc.meta, TranscriptMeta())
        XCTAssertTrue(doc.meta.isEmpty)
        XCTAssertEqual(doc.lines.count, 4)
    }

    func testCleaning() {
        XCTAssertNil(TranscriptMeta.cleanTitle("   "))
        XCTAssertEqual(TranscriptMeta.cleanTitle("  Sync  "), "Sync")
        XCTAssertEqual(TranscriptMeta.cleanTags([" #design ", "Q4", "q4", "", "design"]), ["design", "Q4"])
        var m = TranscriptMeta()
        m.setName("  Priya ", for: zoom)
        XCTAssertEqual(m.names, ["them:us.zoom.xos": "Priya"])
        m.setName("  ", for: zoom)
        XCTAssertEqual(m.names, [:], "a blank name removes the entry")
    }

    // MARK: Name resolution

    func testNamePrecedencePerTranscriptThenYourNameThenDefault() {
        let names = { ["us.zoom.xos": "Zoom"][$0] ?? $0 }
        let none = VoiceNames()
        XCTAssertEqual(none.chipLabel(.me, appName: names), "me")
        XCTAssertEqual(none.chipLabel(zoom, appName: names), "them · Zoom")
        XCTAssertEqual(none.chipLabel(Voice(speaker: .them), appName: names), "them")

        let global = VoiceNames(yourName: "Aditya")
        XCTAssertEqual(global.chipLabel(.me, appName: names), "Aditya", "Settings ▸ Your name replaces the default for me")
        XCTAssertEqual(global.chipLabel(zoom, appName: names), "them · Zoom", "and never touches them")

        let per = VoiceNames(TranscriptMeta(names: ["me": "Me, really", "them:us.zoom.xos": "Priya"]), yourName: "Aditya")
        XCTAssertEqual(per.chipLabel(.me, appName: names), "Me, really", "the transcript's own name wins over Your name")
        XCTAssertEqual(per.chipLabel(zoom, appName: names), "Priya")
        XCTAssertEqual(per.chipLabel(safari, appName: names), "them · com.apple.Safari")
        XCTAssertEqual(VoiceNames(names: ["me": "  "], yourName: "Aditya").chipLabel(.me, appName: names), "Aditya", "a blank entry is no entry")

        // The formatter: Markdown / SRT / text use the same precedence with the "them (Zoom)" default.
        var f = fmt
        XCTAssertEqual(f.label(line(.them, 0, "", app: "us.zoom.xos")), "them (Zoom)")
        f.names = global
        XCTAssertEqual(f.label(line(.me, 0, "")), "Aditya")
        f.names = per
        XCTAssertEqual(f.label(line(.them, 0, "", app: "us.zoom.xos")), "Priya")
        XCTAssertEqual(f.label(line(.me, 0, "")), "Me, really")
        // LaneColors is the UI's door to the same thing.
        XCTAssertEqual(LaneColors.chipLabel(.me, names: per), "Me, really")
        XCTAssertEqual(LaneColors.chipLabel(.me, app: nil), "me")
    }

    // MARK: Markdown header

    func testMarkdownHeaderWithTitleAndTags() {
        let lines = [line(.me, 12, "Hello"), line(.them, 15, "Hi", app: "us.zoom.xos")]
        var f = fmt
        f.names = VoiceNames(sampleMeta, yourName: nil)
        let md = f.markdown(lines: lines, start: t0, end: t0.addingTimeInterval(38 * 60), engine: "e", meta: sampleMeta)
        XCTAssertEqual(md, """
        # Design review
        Mon 9 Nov 2026, 14:03–14:41 (38 min)
        _Tags: design, q4 · Apps heard: Zoom · Engine: e · Made with hearsay, on this Mac._

        **14:03:12 Aditya** Hello

        **14:03:15 Priya** Hi

        """)
        // Tags without a title: the H1 stays the date, tags lead the italic line.
        let tagged = fmt.markdown(lines: [], start: t0, end: nil, engine: "e", meta: TranscriptMeta(tags: ["a", "b"]))
        XCTAssertEqual(tagged, "# Call transcript — Mon 9 Nov 2026, 14:03 – in progress\n_Tags: a, b · Engine: e · Made with hearsay, on this Mac._\n")
        // Nothing set: byte-for-byte the 0.2.0 header.
        XCTAssertEqual(fmt.markdown(lines: [], start: t0, end: nil, engine: "e"), "# Call transcript — Mon 9 Nov 2026, 14:03 – in progress\n_Engine: e · Made with hearsay, on this Mac._\n")
    }

    func testStoreWritesNamesIntoMarkdownAndSRT() throws {
        let store = makeStore(meta: TranscriptMeta(names: ["them:us.zoom.xos": "Priya"]), yourName: "Aditya")
        let md = try String(contentsOf: store.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("**14:03:10 Aditya** Hello from me"), md)
        XCTAssertTrue(md.contains("**14:03:12 Priya** Zoom says hi"), md)
        XCTAssertTrue(md.contains("**14:09:40 them (Safari)** Safari plays a video"), md)
        XCTAssertEqual(store.plainText(hiding: [safari, zoom]), "[14:03:10] Aditya: Hello from me\n[14:09:50] Aditya: Me again")
        let srt = try String(contentsOf: XCTUnwrap(store.exportSRT(hiding: [.me, safari])), encoding: .utf8)
        XCTAssertEqual(srt, "1\n00:00:12,000 --> 00:00:14,000\nPriya: Zoom says hi\n\n")
    }

    /// A rename after the file is finished still reaches it (the live view after Stop).
    func testMetaChangeAfterFinishRewritesTheFiles() throws {
        let store = makeStore()
        store.meta.setTitle("Later title")
        store.waitForWrites()
        XCTAssertTrue(try String(contentsOf: store.markdownURL, encoding: .utf8).hasPrefix("# Later title\n"))
        let side = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(contentsOf: store.jsonURL))
        XCTAssertEqual(side.title, "Later title")
        XCTAssertNotNil(side.endedAt)
    }

    // MARK: Saved transcript edited later

    func testUpdateMetaRewritesASavedTranscript() throws {
        let store = makeStore()
        let before = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(contentsOf: store.jsonURL))
        try TranscriptStore.updateMeta(sampleMeta, at: store.jsonURL, formatter: fmt, yourName: nil)
        let after = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(contentsOf: store.jsonURL))
        XCTAssertEqual(after.meta, sampleMeta)
        XCTAssertEqual(after.lines, before.lines)
        XCTAssertEqual(after.startedAt, before.startedAt)
        XCTAssertEqual(after.endedAt, before.endedAt)
        XCTAssertEqual(after.engine, before.engine)
        let md = try String(contentsOf: store.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.hasPrefix("# Design review\nMon 9 Nov 2026, 14:03–14:41 (38 min)\n_Tags: design, q4 · Apps heard: Zoom, Safari"), md)
        XCTAssertTrue(md.contains("**14:03:12 Priya** Zoom says hi"))
        XCTAssertEqual(store.markdownURL.lastPathComponent, "2026-11-09 14.03 hearsay.md", "the file keeps its date name")
    }

    // MARK: Every export honours the hidden voices

    func testExportsHonourHiddenVoices() throws {
        let store = makeStore(meta: sampleMeta)
        let doc = try XCTUnwrap(TranscriptLibrary.load(store.jsonURL))
        let export = TranscriptExport(document: doc, hiding: [safari], formatter: fmt, yourName: "Ignored: the transcript names me")
        XCTAssertEqual(export.lines.map(\.text), ["Hello from me", "Zoom says hi", "Me again"])
        XCTAssertEqual(export.defaultName, "Design review")

        let md = export.render(.markdown)
        XCTAssertTrue(md.hasPrefix("# Design review\n"))
        XCTAssertTrue(md.contains("**14:03:10 Aditya** Hello from me") && md.contains("**14:03:12 Priya** Zoom says hi"))
        XCTAssertFalse(md.contains("Safari plays a video"))
        XCTAssertTrue(md.contains("Apps heard: Zoom ·"), "the header describes the exported lines, not the hidden ones")

        let json = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(export.render(.json).utf8))
        XCTAssertEqual(json.lines.map(\.text), ["Hello from me", "Zoom says hi", "Me again"])
        XCTAssertEqual(json.meta, sampleMeta)
        XCTAssertEqual(json.lines[1].speaker, .them, "JSON keeps raw voices plus the names map")
        XCTAssertEqual(json.engine, "test-engine")

        XCTAssertEqual(export.render(.text), "Aditya: Hello from me\nPriya: Zoom says hi\nAditya: Me again")

        XCTAssertEqual(export.render(.srt), """
        1
        00:00:10,000 --> 00:00:12,000
        Aditya: Hello from me

        2
        00:00:12,000 --> 00:00:14,000
        Priya: Zoom says hi

        3
        00:06:50,000 --> 00:06:52,000
        Aditya: Me again


        """)

        // Written to disk through the panel's path.
        let out = tmp.appendingPathComponent("out.txt")
        try export.write(.text, to: out)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), export.render(.text))

        // Hiding everything leaves every format empty of lines.
        let nothing = TranscriptExport(document: doc, hiding: [.me, zoom, safari], formatter: fmt, yourName: nil)
        XCTAssertEqual(nothing.render(.text), "")
        XCTAssertEqual(nothing.render(.srt), "")
        XCTAssertFalse(nothing.render(.markdown).contains("**"))

        // The live session goes through the store with the same filter.
        let live = TranscriptExport(store: store, hiding: [.me])
        XCTAssertEqual(live.render(.text), "Priya: Zoom says hi\nthem (Safari): Safari plays a video")
        XCTAssertEqual(live.defaultName, "Design review")
        XCTAssertEqual(TranscriptExport(store: makeStore(), hiding: []).defaultName, "2026-11-09 14.03 hearsay 2", "no title: the file's date name")
    }

    func testFileSafeTitle() {
        XCTAssertEqual(TranscriptExport.fileSafe("Q4: plan / review "), "Q4- plan - review")
        XCTAssertEqual(TranscriptExport.fileSafe("   "), "transcript")
        for f in ExportFormat.allCases { XCTAssertFalse(f.fileExtension.isEmpty); XCTAssertFalse(f.title.isEmpty) }
    }

    // MARK: Sidebar search

    func testSearchMatchesTitleTagsNamesAndText() throws {
        let store = makeStore(meta: sampleMeta)
        let entry = try XCTUnwrap(TranscriptLibrary.parse(Data(contentsOf: store.jsonURL), url: store.jsonURL))
        XCTAssertTrue(entry.matches(""))
        XCTAssertTrue(entry.matches("   "))
        XCTAssertTrue(entry.matches("design REVIEW"), "title, case-insensitive")
        XCTAssertTrue(entry.matches("Q4"), "tag")
        XCTAssertTrue(entry.matches("priya"), "a voice's name")
        XCTAssertTrue(entry.matches("plays a video"), "line text")
        XCTAssertTrue(entry.matches(" video "), "trimmed")
        XCTAssertFalse(entry.matches("budget"))
        XCTAssertFalse(entry.matches("us.zoom"), "bundle ids are not searched")

        let plain = try XCTUnwrap(TranscriptLibrary.parse(Data(contentsOf: makeStore().jsonURL), url: store.jsonURL))
        XCTAssertFalse(plain.matches("design"))
        XCTAssertTrue(plain.matches("hello from"))
    }

    @MainActor
    func testLibraryCollectsTagsAndUpdatesMeta() throws {
        let a = makeStore(meta: TranscriptMeta(tags: ["q4", "design"]))
        let b = TranscriptStore(directory: tmp, startedAt: t0.addingTimeInterval(3600), engine: "e", formatter: fmt, debounce: 0, yourName: { nil })
        b.meta = TranscriptMeta(tags: ["design"])
        b.insert(line(.me, 5, "later session"))
        b.finish(at: t0.addingTimeInterval(3700))

        let lib = TranscriptLibrary(directory: tmp)
        let loaded = expectation(description: "entries")
        let sub = lib.$entries.dropFirst().sink { if $0.count == 2 { loaded.fulfill() } }
        lib.start()
        wait(for: [loaded], timeout: 5)
        sub.cancel()   // setMeta publishes the list again
        XCTAssertEqual(lib.allTags, ["design", "q4"], "most used first, then by name")

        let entry = try XCTUnwrap(lib.entries.first { $0.jsonURL == a.jsonURL })
        lib.setMeta(TranscriptMeta(title: "Renamed", tags: ["q4"]), for: entry)
        XCTAssertEqual(lib.entries.first { $0.jsonURL == a.jsonURL }?.meta.title, "Renamed", "the list changes at once")
        // The files follow on the library's queue.
        let written = expectation(description: "written")
        DispatchQueue.global().async {
            while (try? TranscriptLibrary.load(a.jsonURL))?.meta.title != "Renamed" { Thread.sleep(forTimeInterval: 0.05) }
            written.fulfill()
        }
        wait(for: [written], timeout: 5)
        XCTAssertTrue(try String(contentsOf: a.markdownURL, encoding: .utf8).hasPrefix("# Renamed\n"))
    }

    // MARK: Captions follow a rename

    func testCaptionsUseTheNames() {
        let feed = CaptionsFeed(model: AppModel())
        let session = t0.addingTimeInterval(-10)
        feed.update(lines: [], partials: [.me: "Hello", zoom: "hi"], session: session, now: t0)
        XCTAssertEqual(feed.blocks.map(\.chip), ["me", "them · Zoom"])
        let names = VoiceNames(TranscriptMeta(names: ["them:us.zoom.xos": "Priya"]), yourName: "Aditya")
        feed.update(lines: [], partials: [.me: "Hello", zoom: "hi"], session: session, now: t0.addingTimeInterval(0.5), names: names)
        XCTAssertEqual(feed.blocks.map(\.chip), ["Aditya", "Priya"], "a rename changes the chips without new words")
    }
}
