import XCTest
@testable import hearsay

final class DevModeTests: XCTestCase {
    private let installed = URL(fileURLWithPath: "/Applications/hearsay.app")
    private let repo = URL(fileURLWithPath: "/Users/x/hearsay/build/hearsay.app")

    func testDevDetection() {
        XCTAssertFalse(DevMode.isDev(bundleURL: installed, environment: [:]))
        XCTAssertTrue(DevMode.isDev(bundleURL: repo, environment: [:]))
        XCTAssertTrue(DevMode.isDev(bundleURL: installed, environment: ["HEARSAY_DEV": "1"]))
        XCTAssertFalse(DevMode.isDev(bundleURL: installed, environment: ["HEARSAY_DEV": "0"]))
    }

    func testDevAndInstalledCoexist() {
        XCTAssertEqual(InstanceGuard.conflicts(running: [installed], mine: repo, dev: true), [])
        XCTAssertEqual(InstanceGuard.conflicts(running: [repo], mine: installed, dev: false), [])
        // Dev flag forced on a copy in /Applications: the installed app is still not a conflict.
        XCTAssertEqual(InstanceGuard.conflicts(running: [installed], mine: installed, dev: true), [])
    }

    func testSamePathConflicts() {
        XCTAssertEqual(InstanceGuard.conflicts(running: [repo, installed], mine: repo, dev: true), [repo])
        XCTAssertEqual(InstanceGuard.conflicts(running: [installed], mine: installed, dev: false), [installed])
        let dotted = URL(fileURLWithPath: "/Users/x/hearsay/build/../build/hearsay.app")
        XCTAssertEqual(InstanceGuard.conflicts(running: [dotted], mine: repo, dev: true).count, 1)
    }

    func testPrefsSuiteAndTranscriptsFolder() {
        XCTAssertNil(Prefs.suiteName(dev: false))
        XCTAssertEqual(Prefs.suiteName(dev: true), "dev.hearsay.app.dev")
        let docs = URL(fileURLWithPath: "/Users/x/Documents")
        XCTAssertEqual(DevMode.transcriptsDirectory(dev: false, environment: [:], documents: docs).path, "/Users/x/Documents/hearsay")
        XCTAssertEqual(DevMode.transcriptsDirectory(dev: true, environment: [:], documents: docs).path, "/Users/x/Documents/hearsay-dev")
        XCTAssertEqual(DevMode.transcriptsDirectory(dev: true, environment: ["HEARSAY_TRANSCRIPTS_DIR": "/tmp/t"], documents: docs).path, "/tmp/t")
        XCTAssertEqual(DevMode.controlNotificationName(dev: true), "dev.hearsay.control.dev")
        XCTAssertEqual(DevMode.controlNotificationName(dev: false), "dev.hearsay.control")
    }
}
