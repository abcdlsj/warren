import XCTest
@testable import WarrenDesktop
import WarrenClientCore
import WarrenDomain

final class WarrenDesktopCommandPaletteTests: XCTestCase {
    func testSearchIndexesWorkspaceBranchAndPath() {
        let host = Host(name: "Search Host")
        let project = Project(
            hostID: host.id,
            name: "Warren",
            rootPath: "/Users/me/warren"
        )
        let workspace = Workspace(
            projectID: project.id,
            name: "Review",
            path: "/Users/me/warren-review",
            branch: "feature/search"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace]
        )

        XCTAssertTrue(
            results(for: "feature/search", in: projection).contains {
                if case .workspace(workspace.id) = $0.kind { return true }
                return false
            }
        )
        XCTAssertTrue(
            results(for: "warren-review", in: projection).contains {
                if case .workspace(workspace.id) = $0.kind { return true }
                return false
            }
        )
    }

    func testSearchIndexesCustomSessionTitleAndUsesOpenSessionResult() {
        let host = Host(name: "Search Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(
            projectID: project.id,
            name: "Main",
            path: "/tmp/warren"
        )
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "session-tab",
            title: "Shell",
            sessionID: sessionID
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspace.id,
            tabID: tab.id,
            title: "Shell",
            customTitle: "Deploy API",
            runtimeProcess: "zsh",
            workingDirectory: workspace.path
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [session],
            tabs: [tab]
        )

        let result = results(for: "deploy", in: projection).first {
            if case .session(sessionID) = $0.kind { return true }
            return false
        }

        XCTAssertEqual(result?.title, "Deploy API")
    }

    func testSearchIndexesTerminalGroupTitle() {
        let host = Host(name: "Search Host")
        let group = TerminalGroup(
            hostID: host.id,
            name: "Build Queue",
            home: "/tmp/build"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            groups: [],
            terminalGroups: [group]
        )

        XCTAssertTrue(
            results(for: "queue", in: projection).contains {
                if case .terminalGroup(group.id) = $0.kind { return true }
                return false
            }
        )
    }

    func testSearchIndexesPendingTabTitle() {
        let host = Host(name: "Search Host")
        let tab = ClientTab(
            id: "pending-tab",
            title: "On-call Notes",
            kind: .custom
        )
        let projection = WarrenDesktopProjection(
            host: host,
            groups: [],
            tabs: [tab]
        )

        XCTAssertTrue(
            results(for: "on-call", in: projection).contains {
                if case .tab(tab.id) = $0.kind { return true }
                return false
            }
        )
    }

    func testTerminalContextFocusIntentDefaultsToTrueAndCanBeSuppressed() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Main",
            path: "/tmp/warren"
        )
        let tab = ClientTab(id: "tab", title: "Shell")

        let defaultContext = WarrenDesktopTerminalContext(
            workspace: workspace,
            tab: tab
        )
        let suppressedContext = WarrenDesktopTerminalContext(
            workspace: workspace,
            tab: tab,
            wantsTerminalFocus: false
        )

        XCTAssertTrue(defaultContext.wantsTerminalFocus)
        XCTAssertFalse(suppressedContext.wantsTerminalFocus)
    }

    private func results(
        for query: String,
        in projection: WarrenDesktopProjection
    ) -> [WarrenDesktopCommandPaletteSearch.Result] {
        WarrenDesktopCommandPaletteSearch.results(for: query, in: projection)
    }
}
