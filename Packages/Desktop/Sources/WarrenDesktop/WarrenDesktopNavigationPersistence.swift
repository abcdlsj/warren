import Foundation
import WarrenDomain

/// Device-local persistence for the foreground navigation state.
///
/// Host state owns projects, workspaces, tabs and sessions; this only
/// remembers which workspace/session the window was showing so a relaunch can
/// restore the same view instead of falling back to the first tab.
public enum WarrenDesktopNavigationPersistence {
    private static let selectionKey = "warren.desktop.navigation.selection"
    private static let selectedTabIDKey = "warren.desktop.navigation.selectedTabID"

    public static func restore(from defaults: UserDefaults = .standard) -> WarrenDesktopNavigationState? {
        guard let rawSelection = defaults.string(forKey: selectionKey),
              !rawSelection.isEmpty else { return nil }
        let parts = rawSelection.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        let selection: WarrenDesktopSidebarSelection?
        switch parts[0] {
        case "workspace":
            guard let id = WorkspaceID(uuidString: parts[1]) else { return nil }
            selection = .workspace(id)
        case "project":
            guard let id = ProjectID(uuidString: parts[1]) else { return nil }
            selection = .project(id)
        case "terminal-group":
            guard let id = TerminalGroupID(uuidString: parts[1]) else { return nil }
            selection = .terminalGroup(id)
        default:
            return nil
        }

        return WarrenDesktopNavigationState(
            selection: selection,
            selectedTabID: defaults.string(forKey: selectedTabIDKey)
        )
    }

    public static func save(
        _ state: WarrenDesktopNavigationState,
        to defaults: UserDefaults = .standard
    ) {
        switch state.selection {
        case .workspace(let id):
            defaults.set("workspace:\(id.description)", forKey: selectionKey)
        case .project(let id):
            defaults.set("project:\(id.description)", forKey: selectionKey)
        case .terminalGroup(let id):
            defaults.set("terminal-group:\(id.description)", forKey: selectionKey)
        case nil:
            defaults.removeObject(forKey: selectionKey)
        }
        if let selectedTabID = state.selectedTabID {
            defaults.set(selectedTabID, forKey: selectedTabIDKey)
        } else {
            defaults.removeObject(forKey: selectedTabIDKey)
        }
    }
}
