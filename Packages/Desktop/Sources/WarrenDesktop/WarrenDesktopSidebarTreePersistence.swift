import Foundation
import WarrenDomain

/// Device-local sidebar tree state (which projects are expanded and whether
/// the whole Projects list is collapsed). It is intentionally not Host state:
/// ordering lives on the Host, while expansion is a per-endpoint UI preference.
public struct WarrenDesktopSidebarTreeState: Equatable, Sendable {
    public var expandedProjectIDs: Set<ProjectID>
    public var projectsCollapsed: Bool

    public init(
        expandedProjectIDs: Set<ProjectID> = [],
        projectsCollapsed: Bool = false
    ) {
        self.expandedProjectIDs = expandedProjectIDs
        self.projectsCollapsed = projectsCollapsed
    }
}

/// Device-local persistence for sidebar expansion. The scope key is the
/// selected endpoint ID so Local and Server keep independent trees.
public enum WarrenDesktopSidebarTreePersistence {
    public static func restore(
        scope: String,
        defaults: UserDefaults = .standard
    ) -> WarrenDesktopSidebarTreeState {
        let base = "warren.desktop.sidebar.tree.\(scope)"
        let expanded = (defaults.stringArray(forKey: base + ".expanded") ?? [])
            .compactMap(ProjectID.init(uuidString:))
        return WarrenDesktopSidebarTreeState(
            expandedProjectIDs: Set(expanded),
            projectsCollapsed: defaults.bool(forKey: base + ".collapsed")
        )
    }

    public static func save(
        _ state: WarrenDesktopSidebarTreeState,
        scope: String,
        defaults: UserDefaults = .standard
    ) {
        let base = "warren.desktop.sidebar.tree.\(scope)"
        defaults.set(
            state.expandedProjectIDs
                .map(\.description)
                .sorted(),
            forKey: base + ".expanded"
        )
        defaults.set(state.projectsCollapsed, forKey: base + ".collapsed")
    }
}
