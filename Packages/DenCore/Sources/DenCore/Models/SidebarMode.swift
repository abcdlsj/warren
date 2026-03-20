import Foundation

/// Future-proof enum for sidebar presentation modes.
public enum SidebarMode: String, Codable, Sendable, Equatable {
    case worktrees
    case search
}
