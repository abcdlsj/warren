/// Desktop chrome variants mirror Superset's dashboard and v2 workspace
/// routes. v2 workspace is the default because it merges navigation into the
/// 40pt TabBar and removes the duplicate 48pt TopBar.
public enum BurrowDesktopChromeMode: Hashable, Sendable {
    case dashboard
    case workspace

    public var showsIndependentTopBar: Bool {
        self == .dashboard
    }
}
