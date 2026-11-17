import XCTest
@testable import hearsay

/// Where a dragged bar or pill may be restored.
final class RecordingBarTests: XCTestCase {
    let screen = NSRect(x: 0, y: 0, width: 1470, height: 956)

    /// The user's case: a pill parked bottom-right at y = 23, below the Dock's top edge.
    func testPillLowOnTheScreenIsKept() {
        XCTAssertTrue(RecordingBar.accepts(NSPoint(x: 1169, y: 23), mode: .pill, screens: [screen]))
    }

    func testPillMayHugAnEdgeButNotLeaveTheScreen() {
        XCTAssertTrue(RecordingBar.accepts(NSPoint(x: 0, y: 400), mode: .pill, screens: [screen]))
        XCTAssertFalse(RecordingBar.accepts(NSPoint(x: 2000, y: 400), mode: .pill, screens: [screen]))
        XCTAssertFalse(RecordingBar.accepts(NSPoint(x: 700, y: -50), mode: .pill, screens: [screen]))
    }

    func testBarKeepsFortyPointsOnScreen() {
        XCTAssertFalse(RecordingBar.accepts(NSPoint(x: 20, y: 80), mode: .full, screens: [screen]))
        XCTAssertTrue(RecordingBar.accepts(NSPoint(x: 60, y: 80), mode: .full, screens: [screen]))
    }

    func testASpotOnADisconnectedDisplayIsDropped() {
        XCTAssertFalse(RecordingBar.accepts(NSPoint(x: 2200, y: 300), mode: .pill, screens: [screen]))
        XCTAssertTrue(RecordingBar.accepts(NSPoint(x: 2200, y: 300), mode: .pill,
                                           screens: [screen, NSRect(x: 1470, y: 0, width: 1920, height: 1080)]))
    }
}
