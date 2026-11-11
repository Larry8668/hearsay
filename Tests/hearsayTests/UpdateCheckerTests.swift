import XCTest
@testable import hearsay

/// The daily update check reads GitHub's `releases/latest`; what each reply means for the menu.
final class UpdateCheckerTests: XCTestCase {
    func reply(_ tag: String) -> Data { try! JSONSerialization.data(withJSONObject: ["tag_name": tag]) }

    func testNewerTagIsAvailable() {
        XCTAssertEqual(UpdateChecker.interpret(status: 200, body: reply("v0.3.0"), current: "0.2.0"), .available("0.3.0"))
        XCTAssertEqual(UpdateChecker.interpret(status: 200, body: reply("0.2.10"), current: "0.2.9"), .available("0.2.10"))
    }

    func testSameOrOlderTagIsUpToDate() {
        XCTAssertEqual(UpdateChecker.interpret(status: 200, body: reply("v0.2.0"), current: "0.2.0"), .upToDate("0.2.0"))
        XCTAssertEqual(UpdateChecker.interpret(status: 200, body: reply("0.1.9"), current: "0.2.0"), .upToDate("0.1.9"))
    }

    /// A repository with no release yet answers 404: that is "nothing newer", not a failure.
    func testNoReleaseYetIsUpToDate() {
        XCTAssertEqual(UpdateChecker.interpret(status: 404, body: Data("{\"message\":\"Not Found\"}".utf8), current: "0.2.0"), .upToDate("0.2.0"))
    }

    func testOtherErrorsFail() {
        XCTAssertEqual(UpdateChecker.interpret(status: 403, body: nil, current: "0.2.0"), .failed("HTTP 403"))
        XCTAssertEqual(UpdateChecker.interpret(status: 200, body: Data("not json".utf8), current: "0.2.0"), .failed("unexpected reply"))
    }
}
