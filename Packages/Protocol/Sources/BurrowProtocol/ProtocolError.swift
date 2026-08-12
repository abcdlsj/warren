import Foundation
import BurrowDomain

public enum ProtocolErrorCode: String, Codable, Hashable, Sendable {
    case unsupportedVersion = "unsupported_version"
    case invalidMessage = "invalid_message"
    case unsupportedCapability = "unsupported_capability"
    case sessionNotFound = "session_not_found"
    case attachmentNotFound = "attachment_not_found"
    case controlRequired = "control_required"
    case controlLeaseExpired = "control_lease_expired"
    case staleRecoveryAnchor = "stale_recovery_anchor"
    case invalidFrame = "invalid_frame"
    case sessionExited = "session_exited"
    case internalFailure = "internal_failure"
}

/// An error that can be handled without parsing human text.
public struct ProtocolError: Error, Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    /// Optional routing context. Older peers may omit it; local and future
    /// transports use it to keep concurrent session errors isolated.
    public let sessionID: TerminalSessionID?
    public let code: ProtocolErrorCode
    public let message: String
    public let retryable: Bool

    public init?(
        version: ProtocolVersion = .current,
        sessionID: TerminalSessionID? = nil,
        code: ProtocolErrorCode,
        message: String,
        retryable: Bool = false
    ) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.version = version
        self.sessionID = sessionID
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    private enum CodingKeys: String, CodingKey { case version, sessionID, code, message, retryable }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(ProtocolVersion.self, forKey: .version)
        let sessionID = try container.decodeIfPresent(TerminalSessionID.self, forKey: .sessionID)
        let code = try container.decode(ProtocolErrorCode.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        let retryable = try container.decode(Bool.self, forKey: .retryable)
        guard let value = Self(
            version: version,
            sessionID: sessionID,
            code: code,
            message: message,
            retryable: retryable
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .message,
                in: container,
                debugDescription: "Protocol error message must be actionable and non-empty."
            )
        }
        self = value
    }
}
