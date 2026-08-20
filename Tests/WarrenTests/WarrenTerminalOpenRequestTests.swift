import XCTest
@testable import Warren

final class WarrenTerminalOpenRequestTests: XCTestCase {
    func testParsesTerminalGroupName() throws {
        let request = try XCTUnwrap(
            WarrenTerminalOpenRequest(url: URL(string: "warren://terminal?group=Inbox")!)
        )

        XCTAssertEqual(request.group, "Inbox")
    }

    func testDecodesTerminalGroupName() throws {
        let request = try XCTUnwrap(
            WarrenTerminalOpenRequest(url: URL(string: "warren://terminal?group=Daily%20Shell")!)
        )

        XCTAssertEqual(request.group, "Daily Shell")
    }

    func testMissingGroupUsesDefaultTerminalGroup() throws {
        let request = try XCTUnwrap(
            WarrenTerminalOpenRequest(url: URL(string: "warren://terminal")!)
        )

        XCTAssertNil(request.group)
    }

    func testRejectsUnknownURL() {
        XCTAssertNil(WarrenTerminalOpenRequest(url: URL(string: "https://example.com")!))
        XCTAssertNil(WarrenTerminalOpenRequest(url: URL(string: "warren://project")!))
    }
}
