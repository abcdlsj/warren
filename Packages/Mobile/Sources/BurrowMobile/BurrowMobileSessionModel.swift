import BurrowClientCore
import BurrowDomain

/// Connection tones are pure values so status presentation can be tested
/// without constructing SwiftUI views.
public enum BurrowMobileStatusTone: Hashable, Sendable {
    case positive
    case caution
    case destructive
    case neutral
}

/// Device-local projection of one Host terminal session.
/// The model contains no transport or PTY implementation.
public struct BurrowMobileSessionModel: Hashable, Identifiable, Sendable {
    public let session: TerminalSession
    public var title: String
    public var connectionState: ClientConnectionState
    public var attachmentID: TerminalAttachmentID?
    public var controllerAttachmentID: TerminalAttachmentID?
    public var outputPreview: [String]

    public var id: TerminalSessionID { session.id }

    public init(
        session: TerminalSession,
        title: String,
        connectionState: ClientConnectionState = .disconnected,
        attachmentID: TerminalAttachmentID? = nil,
        controllerAttachmentID: TerminalAttachmentID? = nil,
        outputPreview: [String] = []
    ) {
        self.session = session
        self.title = title
        self.connectionState = connectionState
        self.attachmentID = attachmentID
        self.controllerAttachmentID = controllerAttachmentID
        self.outputPreview = outputPreview
    }

    /// Rejects a projection for a different session instead of presenting it
    /// under the requested navigation destination.
    public init?(
        session: TerminalSession,
        title: String,
        snapshot: ClientSessionSnapshot,
        outputPreview: [String] = []
    ) {
        guard session.id == snapshot.sessionID else { return nil }
        self.init(
            session: session,
            title: title,
            connectionState: snapshot.connectionState,
            attachmentID: snapshot.attachmentID,
            controllerAttachmentID: snapshot.controllerAttachmentID,
            outputPreview: outputPreview
        )
    }

    public var isController: Bool {
        attachmentID != nil && attachmentID == controllerAttachmentID
    }

    public var canSendInput: Bool {
        connectionState == .attached && isController
    }

    public var canRequestControl: Bool {
        connectionState == .attached && attachmentID != nil && !isController
    }

    public var canReconnect: Bool {
        switch connectionState {
        case .disconnected, .failed:
            true
        case .connecting, .attached, .reconnecting, .exited:
            false
        }
    }

    public var connectionLabel: String {
        switch connectionState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .attached: "Connected"
        case .reconnecting: "Reconnecting"
        case .exited: "Exited"
        case .failed: "Connection failed"
        }
    }

    public var controlLabel: String {
        switch connectionState {
        case .attached:
            if isController { return "Controller" }
            return controllerAttachmentID == nil ? "No controller" : "Observer"
        case .disconnected, .connecting, .reconnecting, .exited, .failed:
            return connectionLabel
        }
    }

    public var statusTone: BurrowMobileStatusTone {
        switch connectionState {
        case .attached: isController ? .positive : .neutral
        case .connecting, .reconnecting: .caution
        case .disconnected, .failed: .destructive
        case .exited: .neutral
        }
    }

    public var accessibilityStatus: String {
        "\(connectionLabel), \(controlLabel)"
    }
}
