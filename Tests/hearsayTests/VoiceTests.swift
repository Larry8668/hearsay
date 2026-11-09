import XCTest
@testable import hearsay

/// Voices (speaker + app) key the in-progress text, so two apps playing at once get their own
/// partials and caption blocks.
final class VoiceTests: XCTestCase {
    func testMeNeverCarriesAnApp() {
        XCTAssertEqual(Voice(speaker: .me, app: "us.zoom.xos"), Voice.me)
        XCTAssertNil(Voice(speaker: .me, app: "us.zoom.xos").app)
        XCTAssertEqual(Voice(speaker: .them, app: "us.zoom.xos").app, "us.zoom.xos")
    }

    func testDisplayOrderPutsMeFirstThenAppsByName() {
        let voices: [Voice] = [Voice(speaker: .them, app: "org.mozilla.firefox"), Voice(speaker: .them, app: "app.zen"), .me]
        let sorted = voices.sorted(by: Voice.displayOrder)
        XCTAssertEqual(sorted, [.me, Voice(speaker: .them, app: "app.zen"), Voice(speaker: .them, app: "org.mozilla.firefox")])
    }

    @MainActor
    func testFinalClearsItsVoiceAndTheUnlabelledThemEntry() {
        let model = AppModel()
        let zen = Voice(speaker: .them, app: "app.zen"), firefox = Voice(speaker: .them, app: "org.mozilla.firefox")
        model.partials = [.me: "hello", zen: "video", firefox: "meeting", Voice(speaker: .them): "early words"]
        let line = TranscriptLine(speaker: .them, sourceApp: "app.zen", start: Date(), end: Date(), text: "video done", engine: "t")
        model.insert(line)
        XCTAssertEqual(model.partials, [.me: "hello", firefox: "meeting"])
        model.clearPartials(.them)
        XCTAssertEqual(model.partials, [.me: "hello"])
    }
}
