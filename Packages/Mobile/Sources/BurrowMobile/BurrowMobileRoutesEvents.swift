import BurrowDomain

/// Navigation belongs to this device and is never sent to the Host.
public enum BurrowMobileRoute: Hashable, Sendable {
    case host(HostID)
    case workspace(WorkspaceID)
    case session(TerminalSessionID)
}

/// Button output for the app layer. BurrowMobile does not interpret or send it.
public enum BurrowMobileEvent: Hashable, Sendable {
    case terminalInput(sessionID: TerminalSessionID, key: BurrowMobileTerminalKey)
    case requestControl(sessionID: TerminalSessionID)
    case releaseControl(sessionID: TerminalSessionID)
    case reconnect(sessionID: TerminalSessionID)
    case terminalDismissed(sessionID: TerminalSessionID)
}

/// Explicit keys exposed by the mobile terminal accessory bar.
public enum BurrowMobileTerminalKey: String, CaseIterable, Hashable, Identifiable, Sendable {
    case escape
    case control
    case tab
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight

    public var id: Self { self }

    public var label: String {
        switch self {
        case .escape: "Esc"
        case .control: "Ctrl"
        case .tab: "Tab"
        case .arrowUp: "↑"
        case .arrowDown: "↓"
        case .arrowLeft: "←"
        case .arrowRight: "→"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .control: "Control"
        case .tab: "Tab"
        case .arrowUp: "Arrow up"
        case .arrowDown: "Arrow down"
        case .arrowLeft: "Arrow left"
        case .arrowRight: "Arrow right"
        }
    }
}
