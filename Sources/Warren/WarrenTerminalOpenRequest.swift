import Foundation

/// Commands sent to the running Warren desktop application by launchers such
/// as Raycast. The URL is intentionally small and stable: callers identify a
/// terminal group by its human-readable name, while Warren resolves the
/// current Host-owned ID.
struct WarrenTerminalOpenRequest: Equatable, Sendable {
    static let scheme = "warren"
    static let terminalHost = "terminal"

    let group: String?

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.terminalHost else {
            return nil
        }

        let queryItems = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        let requestedGroup = queryItems.first { $0.name == "group" }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        group = requestedGroup?.isEmpty == false ? requestedGroup : nil
    }
}

enum WarrenAppCommand {
    static let openTerminal = Notification.Name("WarrenAppCommand.openTerminal")
}
