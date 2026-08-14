import XCTest
@testable import WarrenDesignSystem

final class WarrenDesignSystemTests: XCTestCase {
    func testSidebarWidthPolicySnapsAndClamps() {
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 119), 52)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 220), 220)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 320), 320)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 401), 400)
    }

    func testInteractionStatePriority() {
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: true, pressed: true, selected: true, focused: true, hovered: true),
            .disabled
        )
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: false, pressed: true, selected: true, focused: true, hovered: true),
            .pressed
        )
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: false, pressed: false, selected: true, focused: true, hovered: true),
            .selected
        )
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: false, pressed: false, selected: false, focused: true, hovered: true),
            .focused
        )
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: false, pressed: false, selected: false, focused: false, hovered: true),
            .hovered
        )
    }

}
