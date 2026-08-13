import WarrenDomain

/// Names are derived only from the stable Host session identifier.  They do
/// not depend on a workspace title or branch, so renaming UI resources cannot
/// orphan a running tmux session.
public enum TmuxSessionNaming {
    public static let prefix = "warren-"

    public static func name(for sessionID: TerminalSessionID) -> String {
        "\(prefix)\(sessionID.description)"
    }

    public static func isWarrenName(_ name: String) -> Bool {
        guard name.hasPrefix(prefix),
              let id = TerminalSessionID(uuidString: String(name.dropFirst(prefix.count))) else {
            return false
        }
        return name == self.name(for: id)
    }

    public static func sessionID(from name: String) -> TerminalSessionID? {
        guard isWarrenName(name) else { return nil }
        return TerminalSessionID(uuidString: String(name.dropFirst(prefix.count)))
    }
}
