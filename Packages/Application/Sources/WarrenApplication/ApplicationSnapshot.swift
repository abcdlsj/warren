import WarrenClientCore
import WarrenDomain
import WarrenHost
import WarrenStateStore
import Foundation

public enum WarrenApplicationLifecycle: Hashable, Sendable {
    case idle
    case starting
    case ready
    case failed
    case stopping
}

public enum WarrenApplicationConnectionState: Hashable, Sendable {
    case disconnected
    case connecting
    case attached
    case reconnecting
    case exited
    case failed
}

/// The immutable output projection used by a future `@Observable` model.
///
/// Frames are bounded by Host's OutputRing. Keeping them as values makes the
/// actor boundary explicit and gives a renderer enough bytes to catch up
/// without exposing Host or Client actors to SwiftUI.
public struct WarrenApplicationOutputSnapshot: Hashable, Sendable {
    public let sessionID: TerminalSessionID
    public let epoch: UInt64
    public let lowerSequence: UInt64
    public let upperSequence: UInt64
    public let frames: [TerminalOutputFrame]

    public init(
        sessionID: TerminalSessionID,
        epoch: UInt64,
        lowerSequence: UInt64,
        upperSequence: UInt64,
        frames: [TerminalOutputFrame] = []
    ) {
        self.sessionID = sessionID
        self.epoch = epoch
        self.lowerSequence = lowerSequence
        self.upperSequence = upperSequence
        self.frames = frames
    }

    public init(sessionID: TerminalSessionID, ring: OutputRingSnapshot) {
        self.init(
            sessionID: sessionID,
            epoch: ring.epoch,
            lowerSequence: ring.lowerSequence,
            upperSequence: ring.upperSequence,
            frames: ring.frames
        )
    }

    public var anchor: RecoveryAnchor {
        RecoveryAnchor(epoch: epoch, sequence: upperSequence)
    }
}

/// One live or restored terminal tab. It contains no UI object or process
/// handle; the desktop layer can build SwiftTerm views from its value fields.
public struct WarrenApplicationSession: Identifiable, Hashable, Sendable {
    public let id: TerminalSessionID
    public let workspaceID: WorkspaceID
    public let tabID: String
    public let title: String
    public let kind: TerminalSessionKind
    public let connectionState: WarrenApplicationConnectionState
    public let activityState: TerminalSessionActivityState
    public let attachmentID: TerminalAttachmentID?
    public let controllerAttachmentID: TerminalAttachmentID?
    public let controlLeaseID: ControlLeaseID?
    public let recoveryAnchor: RecoveryAnchor?
    public let terminalSize: TerminalSize
    public let runtimeAdoptionDescriptor: RuntimeAdoptionDescriptor?
    public let output: WarrenApplicationOutputSnapshot?

    public init(
        id: TerminalSessionID,
        workspaceID: WorkspaceID,
        tabID: String,
        title: String,
        kind: TerminalSessionKind = .shell,
        connectionState: WarrenApplicationConnectionState,
        activityState: TerminalSessionActivityState? = nil,
        attachmentID: TerminalAttachmentID? = nil,
        controllerAttachmentID: TerminalAttachmentID? = nil,
        controlLeaseID: ControlLeaseID? = nil,
        recoveryAnchor: RecoveryAnchor? = nil,
        terminalSize: TerminalSize,
        runtimeAdoptionDescriptor: RuntimeAdoptionDescriptor? = nil,
        output: WarrenApplicationOutputSnapshot? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.title = title
        self.kind = kind
        self.connectionState = connectionState
        self.activityState = activityState ?? Self.defaultActivity(for: connectionState)
        self.attachmentID = attachmentID
        self.controllerAttachmentID = controllerAttachmentID
        self.controlLeaseID = controlLeaseID
        self.recoveryAnchor = recoveryAnchor
        self.terminalSize = terminalSize
        self.runtimeAdoptionDescriptor = runtimeAdoptionDescriptor
        self.output = output
    }

    private static func defaultActivity(
        for connectionState: WarrenApplicationConnectionState
    ) -> TerminalSessionActivityState {
        switch connectionState {
        case .attached: .working
        case .connecting, .reconnecting, .disconnected: .connecting
        case .exited: .exited
        case .failed: .failed
        }
    }
}

/// Complete immutable state emitted by WarrenApplicationService.
public struct WarrenApplicationSnapshot: Hashable, Sendable {
    public let host: WarrenDomain.Host
    public let projects: [Project]
    public let workspaces: [Workspace]
    public let sessions: [WarrenApplicationSession]
    public let windowLayout: ClientWindowLayout
    public let issues: [WarrenApplicationIssue]
    public let lifecycle: WarrenApplicationLifecycle

    public init(
        host: WarrenDomain.Host,
        projects: [Project] = [],
        workspaces: [Workspace] = [],
        sessions: [WarrenApplicationSession] = [],
        windowLayout: ClientWindowLayout = WarrenApplicationDefaults.emptyWindowLayout,
        issues: [WarrenApplicationIssue] = [],
        lifecycle: WarrenApplicationLifecycle = .idle
    ) {
        self.host = host
        self.projects = projects
        self.workspaces = workspaces
        self.sessions = sessions
        self.windowLayout = windowLayout
        self.issues = issues
        self.lifecycle = lifecycle
    }

    public static func empty(host: WarrenDomain.Host = WarrenApplicationDefaults.localHost) -> Self {
        Self(host: host)
    }

    public func workspace(id: WorkspaceID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    public func session(id: TerminalSessionID) -> WarrenApplicationSession? {
        sessions.first { $0.id == id }
    }

    /// Returns the sessions currently represented in one workspace.
    ///
    /// The projection intentionally keeps sessions and workspaces as separate
    /// collections.  This helper is the safe read boundary for a shell that
    /// needs to render a workspace's tabs; callers do not have to rebuild the
    /// relationship (or accidentally mix sessions from another workspace).
    public func sessions(in workspaceID: WorkspaceID) -> [WarrenApplicationSession] {
        sessions.filter { $0.workspaceID == workspaceID }
    }

    public func tabs(in workspaceID: WorkspaceID) -> [ClientTab] {
        windowLayout.workspaceView(for: workspaceID)?.tabs ?? []
    }

    public var activeWorkspaceView: ClientWorkspaceView? {
        windowLayout.activeWorkspaceView
    }
}

public enum WarrenApplicationDefaults {
    public static let localHost = WarrenDomain.Host(
        id: HostID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!),
        name: "Local Mac"
    )

    public static let localClientID = ClientID(
        rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000000010")!
    )

    public static let mainWindowID = ClientWindowID(
        rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000000011")!
    )

    public static let emptyWindowLayout = ClientWindowLayout(id: mainWindowID)!

    public static func stateDatabaseURL(fileManager: FileManager = .default) -> URL {
        if let override = ProcessInfo.processInfo.environment["WARREN_STATE_DATABASE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Warren/state.sqlite3", isDirectory: false)
    }

    public static func runtimeOutputDirectory(fileManager: FileManager = .default) -> URL {
        if let override = ProcessInfo.processInfo.environment["WARREN_RUNTIME_OUTPUT_DIRECTORY"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Warren/runtime", isDirectory: true)
    }

    public static func supersetDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".superset/local.db", isDirectory: false)
    }
}
