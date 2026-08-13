import XCTest
@testable import WarrenDesignSystem

final class WarrenDesignSystemTests: XCTestCase {
    func testSupersetLayoutMeasurementsAreCentralized() {
        XCTAssertEqual(WarrenLayoutMetrics.sidebarExpandedWidth, 280)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarCollapsedWidth, 52)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarMinimumWidth, 220)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarMaximumWidth, 400)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarSnapThreshold, 120)
        XCTAssertEqual(WarrenLayoutMetrics.topBarHeight, 48)
        XCTAssertEqual(WarrenLayoutMetrics.workspaceBarHeight, 48)
        XCTAssertEqual(WarrenLayoutMetrics.workspaceBarProjectWidth, 160)
        XCTAssertEqual(WarrenLayoutMetrics.workspaceBarWorkspaceWidth, 240)
        XCTAssertEqual(WarrenLayoutMetrics.tabBarHeight, 40)
        XCTAssertEqual(WarrenLayoutMetrics.tabWidth, 160)
        XCTAssertEqual(WarrenLayoutMetrics.tabAddButtonSlotWidth, 40)
        XCTAssertEqual(WarrenLayoutMetrics.tabCloseButtonSize, 20)
        XCTAssertEqual(WarrenLayoutMetrics.tabAccessoryColumnWidth, 28)
        XCTAssertEqual(WarrenLayoutMetrics.paneHeaderHeight, 28)
        XCTAssertEqual(WarrenLayoutMetrics.paneMinimumWidth, 260)
        XCTAssertEqual(WarrenLayoutMetrics.paneMinimumHeight, 160)
        XCTAssertEqual(WarrenLayoutMetrics.inspectorDefaultWidth, 340)
        XCTAssertEqual(WarrenLayoutMetrics.inspectorMinimumWidth, 240)
        XCTAssertEqual(WarrenLayoutMetrics.inspectorMaximumWidth, 640)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarProjectRowHeight, 28)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWorkspaceRowHeight, 26)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarSectionLabelHeight, 28)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarRowIconSlotSize, 18)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarActionButtonSize, 24)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarScrollFadeLength, 24)
    }

    func testSidebarWidthPolicySnapsAndClamps() {
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 119), 52)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 220), 220)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 320), 320)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 401), 400)
    }

    func testEmberSemanticColorRolesExposeTabHoverWash() {
        let dark = WarrenColorTokens.dark

        // Color intentionally remains opaque to this package's callers. These
        // checks ensure the semantic roles exist and are not accidentally
        // replaced by an absent/empty token while preserving platform color
        // resolution inside SwiftUI.
        XCTAssertFalse(String(describing: dark.fillHover).isEmpty)
        XCTAssertFalse(String(describing: dark.fillSelected).isEmpty)
        XCTAssertFalse(String(describing: dark.tabInactiveHover).isEmpty)
        XCTAssertFalse(String(describing: dark.highlight).isEmpty)
        XCTAssertFalse(String(describing: dark.wash(.hover)).isEmpty)
        XCTAssertFalse(String(describing: dark.wash(.selected)).isEmpty)
        XCTAssertFalse(String(describing: dark.wash(.tertiary)).isEmpty)
    }
}
