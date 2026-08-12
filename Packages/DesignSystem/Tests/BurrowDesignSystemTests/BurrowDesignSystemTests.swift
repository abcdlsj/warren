import XCTest
@testable import BurrowDesignSystem

final class BurrowDesignSystemTests: XCTestCase {
    func testSupersetLayoutMeasurementsAreCentralized() {
        XCTAssertEqual(BurrowLayoutMetrics.sidebarExpandedWidth, 280)
        XCTAssertEqual(BurrowLayoutMetrics.sidebarCollapsedWidth, 52)
        XCTAssertEqual(BurrowLayoutMetrics.sidebarMinimumWidth, 220)
        XCTAssertEqual(BurrowLayoutMetrics.sidebarMaximumWidth, 400)
        XCTAssertEqual(BurrowLayoutMetrics.sidebarSnapThreshold, 120)
        XCTAssertEqual(BurrowLayoutMetrics.topBarHeight, 48)
        XCTAssertEqual(BurrowLayoutMetrics.workspaceBarHeight, 48)
        XCTAssertEqual(BurrowLayoutMetrics.workspaceBarProjectWidth, 160)
        XCTAssertEqual(BurrowLayoutMetrics.workspaceBarWorkspaceWidth, 240)
        XCTAssertEqual(BurrowLayoutMetrics.tabBarHeight, 40)
        XCTAssertEqual(BurrowLayoutMetrics.tabWidth, 160)
        XCTAssertEqual(BurrowLayoutMetrics.tabAddButtonSlotWidth, 40)
        XCTAssertEqual(BurrowLayoutMetrics.tabCloseButtonSize, 20)
        XCTAssertEqual(BurrowLayoutMetrics.tabAccessoryColumnWidth, 28)
        XCTAssertEqual(BurrowLayoutMetrics.paneHeaderHeight, 28)
        XCTAssertEqual(BurrowLayoutMetrics.paneMinimumWidth, 260)
        XCTAssertEqual(BurrowLayoutMetrics.paneMinimumHeight, 160)
        XCTAssertEqual(BurrowLayoutMetrics.inspectorDefaultWidth, 340)
        XCTAssertEqual(BurrowLayoutMetrics.inspectorMinimumWidth, 240)
        XCTAssertEqual(BurrowLayoutMetrics.inspectorMaximumWidth, 640)
        XCTAssertEqual(BurrowLayoutMetrics.sidebarProjectRowHeight, 28)
        XCTAssertEqual(BurrowLayoutMetrics.sidebarWorkspaceRowHeight, 26)
        XCTAssertEqual(BurrowLayoutMetrics.sidebarSectionLabelHeight, 28)
        XCTAssertEqual(BurrowLayoutMetrics.sidebarRowIconSlotSize, 18)
        XCTAssertEqual(BurrowLayoutMetrics.sidebarActionButtonSize, 24)
        XCTAssertEqual(BurrowLayoutMetrics.sidebarScrollFadeLength, 24)
    }

    func testSidebarWidthPolicySnapsAndClamps() {
        XCTAssertEqual(BurrowLayoutMetrics.sidebarWidth(for: 119), 52)
        XCTAssertEqual(BurrowLayoutMetrics.sidebarWidth(for: 220), 220)
        XCTAssertEqual(BurrowLayoutMetrics.sidebarWidth(for: 320), 320)
        XCTAssertEqual(BurrowLayoutMetrics.sidebarWidth(for: 401), 400)
    }

    func testEmberSemanticColorRolesExposeTabHoverWash() {
        let dark = BurrowColorTokens.dark

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
