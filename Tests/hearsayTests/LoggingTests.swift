import XCTest
@testable import hearsay

final class LoggingTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("hearsay-log-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testManagedSetIsBaseNamePlusThreeRolled() {
        XCTAssertEqual(Log.managedNames(baseNames: ["hearsay.log", "hearsay-dev.log"]), [
            "hearsay.log", "hearsay.log.1", "hearsay.log.2", "hearsay.log.3",
            "hearsay-dev.log", "hearsay-dev.log.1", "hearsay-dev.log.2", "hearsay-dev.log.3"])
        XCTAssertEqual(Log.managedNames(baseNames: ["a.log"], rolled: 1), ["a.log", "a.log.1"])
    }

    func testPruneDeletesStraysAndOldRolledFilesOnly() throws {
        let dir = try tempDir()
        let now = Date()
        let old = now.addingTimeInterval(-40 * 24 * 3600)
        func make(_ name: String, modified: Date = now) throws {
            let u = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: u.path)
        }
        try make("hearsay.log", modified: old)          // live files are never age-pruned
        try make("hearsay.log.1")
        try make("hearsay.log.2", modified: old)        // too old
        try make("hearsay.log.3")
        try make("hearsay.log.4")                       // beyond the cap
        try make("hearsay-dev.log")
        try make("hearsay-dev.log.1")
        try make("crash.txt")
        Log.prune(in: dir, now: now, baseNames: ["hearsay.log", "hearsay-dev.log"])
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left, ["hearsay.log", "hearsay.log.1", "hearsay.log.3", "hearsay-dev.log", "hearsay-dev.log.1"])
    }

    func testLineFormatHasLevelAndCategory() {
        let line = Log.format(date: Date(timeIntervalSince1970: 0), level: "INFO", category: .engine, message: "started")
        XCTAssertTrue(line.hasSuffix("[INFO] [engine] started\n"), line)
        XCTAssertEqual(Set(Log.Category.allCases.map(\.rawValue)),
                       ["mic", "tap", "engine", "session", "ui", "update", "model", "diarize", "app"])
    }

    func testSessionMarkers() {
        let start = Log.sessionStartLine(at: Date(timeIntervalSince1970: 0), sources: ["me", "them"], engine: "parakeet", echo: "auto")
        XCTAssertTrue(start.hasPrefix("===== session start "))
        XCTAssertTrue(start.hasSuffix("· sources me+them · engine parakeet · echo auto ====="), start)
        XCTAssertEqual(Log.sessionEndLine(duration: 38 * 60, lines: 48, saved: "a.md"), "===== session end · 38 min · 48 lines · saved a.md =====")
        XCTAssertTrue(Log.sessionEndLine(duration: 20, lines: 0, saved: nil).contains("20 s · 0 lines · saved nothing"))
    }

    func testSpokenTextIsOnlyLoggedWhenVerbose() {
        let text = "my secret sentence about pineapples"
        XCTAssertFalse(Log.describe(text: text, verbose: false).contains("pineapples"))
        XCTAssertTrue(Log.describe(text: text, verbose: false).contains("5 words"))
        XCTAssertTrue(Log.describe(text: text, verbose: true).contains("pineapples"))
    }

    func testReportNeverIncludesTranscriptText() throws {
        let dir = try tempDir()
        let secret = "the launch code is pineapple"
        try Data("{\"lines\":[{\"text\":\"\(secret)\"}]}".utf8).write(to: dir.appendingPathComponent("2026-11-12 10.00 hearsay.json"))
        try Data(secret.utf8).write(to: dir.appendingPathComponent("2026-11-12 10.00 hearsay.md"))
        var i = Diagnostics.Inputs()
        i.settings = ["echoCancellation": "auto", "verboseLogging": "0"]
        i.transcriptFolder = dir.path
        i.transcriptCount = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.count
        i.models = ["parakeet/160ms  400 MB"]
        let r = Diagnostics.report(i)
        XCTAssertFalse(r.contains("pineapple"))
        XCTAssertTrue(r.contains("transcripts: 1 in "))
        XCTAssertTrue(r.contains("echoCancellation = auto"))
        XCTAssertTrue(r.contains("parakeet/160ms  400 MB"))
    }
}
