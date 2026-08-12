import BurrowDomain
import BurrowProtocol
import Foundation

/// Errors at the macOS composition boundary.
///
/// The cases are intentionally typed so a view can offer a useful recovery
/// action without matching human-readable log messages.
public enum BurrowApplicationError: Error, Hashable, Sendable, LocalizedError {
    case alreadyStarted
    case notStarted
    case invalidLifecycle(BurrowApplicationLifecycle)
    case projectPathInvalid(String)
    case projectAlreadyExists(String)
    case projectNotFound(ProjectID)
    case projectWorkspaceMissing(ProjectID)
    case workspaceNotFound(WorkspaceID)
    case sessionNotFound(TerminalSessionID)
    case attachmentNotFound(TerminalAttachmentID)
    case tabNotFound(String)
    case repository(String)
    case runtime(String)
    case transport(String)
    case protocolFailure(ProtocolError)
    case unsupportedAction(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "Burrow is already running."
        case .notStarted:
            return "Burrow is not running."
        case let .invalidLifecycle(lifecycle):
            return "Burrow is in state \(lifecycle) and cannot perform this action."
        case let .projectPathInvalid(path):
            return "Cannot add \(path) as a project."
        case let .projectAlreadyExists(path):
            return "Project already exists: \(path)."
        case .projectNotFound:
            return "Target project not found."
        case .projectWorkspaceMissing:
            return "Project has no root workspace."
        case .workspaceNotFound:
            return "Target workspace not found."
        case .sessionNotFound:
            return "Target terminal session not found."
        case .attachmentNotFound:
            return "Target terminal attachment not found."
        case let .tabNotFound(tabID):
            return "Tab \(tabID) not found."
        case let .repository(reason):
            return "Cannot save or load local state: \(reason)"
        case let .runtime(reason):
            return "Local terminal runtime operation failed: \(reason)"
        case let .transport(reason):
            return "Local Host transport failed: \(reason)"
        case let .protocolFailure(error):
            return "Terminal protocol operation failed: \(error.message)"
        case let .unsupportedAction(action):
            return "Not supported in this version: \(action)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .alreadyStarted:
            return "Continue using the current app instance."
        case .notStarted, .invalidLifecycle:
            return "Start Burrow before managing projects or terminals."
        case .projectPathInvalid:
            return "Select an existing, readable folder."
        case .projectAlreadyExists:
            return "Select the existing project from the sidebar."
        case .projectNotFound, .projectWorkspaceMissing:
            return "Refresh the window and select an existing project."
        case .workspaceNotFound:
            return "Refresh the window and select a workspace."
        case .sessionNotFound, .attachmentNotFound, .tabNotFound:
            return "Refresh the window; if the issue persists, reopen the tab."
        case .repository:
            return "Check read/write access to Burrow's state directory, then retry."
        case .runtime:
            return "Ensure tmux is available and the project directory still exists, then retry."
        case .transport:
            return "Reopen the terminal tab to reconnect the local Host."
        case let .protocolFailure(error):
            return error.retryable
                ? "Retry later; if the issue persists, reconnect the terminal."
                : "Check the current tab state, then reconnect."
        case .unsupportedAction:
            return "This version supports local projects, workspaces, and terminal sessions only."
        }
    }
}

public enum BurrowApplicationIssueSeverity: String, Codable, Hashable, Sendable {
    case info
    case warning
    case error
}

/// A non-fatal issue retained in the value snapshot for the shell to render.
public struct BurrowApplicationIssue: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let severity: BurrowApplicationIssueSeverity
    public let title: String
    public let detail: String
    public let recoverySuggestion: String

    public init(
        id: String,
        severity: BurrowApplicationIssueSeverity = .warning,
        title: String,
        detail: String,
        recoverySuggestion: String
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.recoverySuggestion = recoverySuggestion
    }

    public init(id: String, error: Error, recoverySuggestion: String = "Please try again.") {
        let localized = error as? LocalizedError
        self.init(
            id: id,
            severity: .error,
            title: localized?.errorDescription ?? "Burrow operation failed",
            detail: String(describing: error),
            recoverySuggestion: localized?.recoverySuggestion ?? recoverySuggestion
        )
    }
}

extension BurrowApplicationError {
    internal var issue: BurrowApplicationIssue {
        BurrowApplicationIssue(
            id: "application.\(String(describing: self))",
            severity: .error,
            title: errorDescription ?? "Burrow operation failed",
            detail: String(describing: self),
            recoverySuggestion: recoverySuggestion ?? "Please try again."
        )
    }
}

extension Error {
    internal var asApplicationError: BurrowApplicationError {
        if let error = self as? BurrowApplicationError { return error }
        if let error = self as? ProtocolError { return .protocolFailure(error) }
        return .runtime(String(describing: self))
    }
}
