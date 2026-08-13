import Foundation
import WarrenDomain

/// Value-only fixture for the Host → Workspace → Session mobile slice.
public struct WarrenMobileFixture: Hashable, Sendable {
    public let hosts: [WarrenDomain.Host]
    public let projects: [Project]
    public let workspaces: [Workspace]
    public let sessions: [WarrenMobileSessionModel]

    public init(
        hosts: [WarrenDomain.Host],
        projects: [Project],
        workspaces: [Workspace],
        sessions: [WarrenMobileSessionModel]
    ) {
        self.hosts = hosts
        self.projects = projects
        self.workspaces = workspaces
        self.sessions = sessions
    }

    public func host(for id: HostID) -> WarrenDomain.Host? {
        hosts.first { $0.id == id }
    }

    public func project(for id: ProjectID) -> Project? {
        projects.first { $0.id == id }
    }

    public func project(for workspace: Workspace) -> Project? {
        project(for: workspace.projectID)
    }

    public func workspace(for id: WorkspaceID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    public func session(for id: TerminalSessionID) -> WarrenMobileSessionModel? {
        sessions.first { $0.id == id }
    }

    public func workspaces(for hostID: HostID) -> [Workspace] {
        let projectIDs = Set(projects.filter { $0.hostID == hostID }.map(\.id))
        return workspaces.filter { projectIDs.contains($0.projectID) }
    }

    public func sessions(for workspaceID: WorkspaceID) -> [WarrenMobileSessionModel] {
        sessions.filter { $0.session.workspaceID == workspaceID }
    }

    /// Deterministic data for previews and screenshots before a transport is
    /// connected. IDs are stable, so navigation identity is stable as well.
    public static func sample() -> Self {
        let hostID = HostID(rawValue: fixtureUUID("00000000-0000-0000-0000-000000000001"))
        let projectID = ProjectID(rawValue: fixtureUUID("00000000-0000-0000-0000-000000000002"))
        let mainWorkspaceID = WorkspaceID(rawValue: fixtureUUID("00000000-0000-0000-0000-000000000003"))
        let reviewWorkspaceID = WorkspaceID(rawValue: fixtureUUID("00000000-0000-0000-0000-000000000004"))
        let controllerSessionID = TerminalSessionID(rawValue: fixtureUUID("00000000-0000-0000-0000-000000000005"))
        let disconnectedSessionID = TerminalSessionID(rawValue: fixtureUUID("00000000-0000-0000-0000-000000000006"))
        let attachmentID = TerminalAttachmentID(rawValue: fixtureUUID("00000000-0000-0000-0000-000000000007"))

        let host = WarrenDomain.Host(id: hostID, name: "Mac Studio")
        let project = Project(id: projectID, hostID: hostID, name: "Warren", rootPath: "~/Workspace/warren")
        let mainWorkspace = Workspace(
            id: mainWorkspaceID, projectID: projectID, name: "warren-main",
            path: "~/Workspace/warren", branch: "main"
        )
        let reviewWorkspace = Workspace(
            id: reviewWorkspaceID, projectID: projectID, name: "warren-review",
            path: "~/Workspace/warren-review", branch: "release/mobile-shell"
        )
        let controllerSession = WarrenMobileSessionModel(
            session: TerminalSession(id: controllerSessionID, workspaceID: mainWorkspaceID, epoch: 1, sequence: 128),
            title: "Shell", connectionState: .attached,
            attachmentID: attachmentID, controllerAttachmentID: attachmentID,
            outputPreview: ["$ warren status", "workspace  warren-main", "branch     main", "", "Terminal placeholder — no PTY attached"]
        )
        let disconnectedSession = WarrenMobileSessionModel(
            session: TerminalSession(id: disconnectedSessionID, workspaceID: reviewWorkspaceID, epoch: 2, sequence: 64),
            title: "Review shell", connectionState: .disconnected,
            outputPreview: ["$ git status --short", "(last output retained locally)"]
        )

        return Self(
            hosts: [host], projects: [project],
            workspaces: [mainWorkspace, reviewWorkspace],
            sessions: [controllerSession, disconnectedSession]
        )
    }

    public static var preview: Self { sample() }
}

private func fixtureUUID(_ value: String) -> UUID {
    guard let uuid = UUID(uuidString: value) else {
        preconditionFailure("Invalid WarrenMobile fixture UUID: \(value)")
    }
    return uuid
}
