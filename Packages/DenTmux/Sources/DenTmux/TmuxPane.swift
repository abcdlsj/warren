import Foundation

/// Direction enum mapped onto tmux pane-selection and pane-resize flags.
public enum PaneDirection: String, Sendable {
    case up = "U"
    case down = "D"
    case left = "L"
    case right = "R"
    case next = "next"
    case previous = "previous"

    var selectTarget: String? {
        switch self {
        case .next: return "{next}"
        case .previous: return "{previous}"
        default: return nil
        }
    }
}

public struct TmuxPane: Identifiable, Equatable, Sendable {
    public var id: String { paneId }
    public let paneId: String
    public let tty: String?
    public let isActive: Bool
    public let currentPath: String?
    public let title: String?
    public let lastActivity: TimeInterval?
    public let currentCommand: String?
    public let startTime: TimeInterval?

    public init(
        paneId: String,
        tty: String? = nil,
        isActive: Bool = false,
        currentPath: String? = nil,
        title: String? = nil,
        lastActivity: TimeInterval? = nil,
        currentCommand: String? = nil,
        startTime: TimeInterval? = nil
    ) {
        self.paneId = paneId
        self.tty = tty
        self.isActive = isActive
        self.currentPath = currentPath
        self.title = title
        self.lastActivity = lastActivity
        self.currentCommand = currentCommand
        self.startTime = startTime
    }
}
