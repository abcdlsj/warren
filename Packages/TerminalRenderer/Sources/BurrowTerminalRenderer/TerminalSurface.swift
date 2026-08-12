import Foundation
import BurrowDomain

/// An opaque identity for a rendered surface. It is deliberately independent
/// from `TerminalSessionID`: destroying this value must never destroy a host
/// session.
public struct TerminalSurfaceID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }
}

/// A renderer-owned view identity bound to one attachment. The attachment is
/// a connection identity, not a session-lifecycle owner.
public struct TerminalSurface: Identifiable, Codable, Hashable, Sendable {
    public let id: TerminalSurfaceID
    public let attachment: TerminalAttachment

    public init(id: TerminalSurfaceID = TerminalSurfaceID(), attachment: TerminalAttachment) {
        self.id = id
        self.attachment = attachment
    }

    public var sessionID: TerminalSessionID { attachment.sessionID }
    public var attachmentID: TerminalAttachmentID { attachment.id }
    public var clientID: ClientID { attachment.clientID }
}
