import Foundation
import WarrenDomain

/// Device-local tab ordering for each resource scope. IDs are stored as raw
/// strings so a layout can survive a reconnect before the remote roster has
/// been decoded, while callers still validate them against their domain type.
public struct WarrenDesktopTabOrders: Codable, Hashable, Sendable {
    public var workspace: [String: [String]]
    public var terminalGroup: [String: [String]]

    public init(
        workspace: [String: [String]] = [:],
        terminalGroup: [String: [String]] = [:]
    ) {
        self.workspace = workspace
        self.terminalGroup = terminalGroup
    }
}

/// Device-local persistence for foreground navigation and scope-local tab
/// ordering.
///
/// Host state owns projects, workspaces, and sessions; this remembers which
/// scope/session the window was showing and how its tabs were arranged so a
/// relaunch can restore the same view instead of falling back to roster order.
public enum WarrenDesktopNavigationPersistence {
    private static let selectionKey = "warren.desktop.navigation.selection"
    private static let selectedTabIDKey = "warren.desktop.navigation.selectedTabID"
    private static let memoryKey = "warren.desktop.navigation.memory"
    private static let tabOrdersKey = "warren.desktop.navigation.tabOrders"

    public static func restore(from defaults: UserDefaults = .standard) -> WarrenDesktopNavigationState? {
        let memory = restoreMemory(from: defaults)
        guard let rawSelection = defaults.string(forKey: selectionKey),
              !rawSelection.isEmpty else {
            return memory.isEmpty
                ? nil
                : WarrenDesktopNavigationState(memory: memory)
        }
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
            selectedTabID: defaults.string(forKey: selectedTabIDKey),
            memory: memory
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
        guard let data = try? JSONEncoder().encode(state.memory) else { return }
        defaults.set(data, forKey: memoryKey)
    }

    private static func restoreMemory(
        from defaults: UserDefaults
    ) -> WarrenDesktopNavigationMemory {
        guard let data = defaults.data(forKey: memoryKey),
              let memory = try? JSONDecoder().decode(
                  WarrenDesktopNavigationMemory.self,
                  from: data
              ) else {
            return WarrenDesktopNavigationMemory()
        }
        return memory
    }

    public static func restoreTabOrders(
        from defaults: UserDefaults = .standard
    ) -> WarrenDesktopTabOrders {
        guard let data = defaults.data(forKey: tabOrdersKey),
              let orders = try? JSONDecoder().decode(WarrenDesktopTabOrders.self, from: data) else {
            return WarrenDesktopTabOrders()
        }
        return orders
    }

    public static func saveTabOrders(
        _ orders: WarrenDesktopTabOrders,
        to defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(orders) else { return }
        defaults.set(data, forKey: tabOrdersKey)
    }
}
