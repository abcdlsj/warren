import XCTest
@testable import WarrenDesignSystem

final class WarrenDesignSystemTests: XCTestCase {
    func testSidebarWidthPolicySnapsAndClamps() {
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 119), 52)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 220), 220)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 320), 320)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 401), 400)
    }

}
