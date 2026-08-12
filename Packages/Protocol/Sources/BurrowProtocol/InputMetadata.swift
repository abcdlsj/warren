import Foundation
import BurrowDomain

/// Stable metadata for one Client-to-Host terminal input payload.
///
/// `InputMetadata` describes bytes; it never owns them. The payload is carried
/// by the binary envelope and `payloadLength` must equal that envelope's payload
/// length. `sequence` is an optional client emission ordinal only. Protocol
/// 1.0 has no input acknowledgement or deduplication message, so Hosts must
/// not treat it as an idempotency key; it is intentionally advisory until a
/// future protocol version defines acknowledgement semantics.
public struct InputMetadata: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let sessionID: TerminalSessionID
    public let attachmentID: TerminalAttachmentID
    public let payloadLength: Int
    public let sequence: UInt64?

    /// Protocol 1.0 does not provide input ACK/deduplication semantics.
    public static let supportsIdempotentSequence = false

    public init?(
        version: ProtocolVersion = .current,
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        payloadLength: Int,
        sequence: UInt64? = nil
    ) {
        guard payloadLength >= 0 else { return nil }
        self.version = version
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.payloadLength = payloadLength
        self.sequence = sequence
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sessionID
        case attachmentID
        case payloadLength
        case sequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(ProtocolVersion.self, forKey: .version)
        let sessionID = try container.decode(TerminalSessionID.self, forKey: .sessionID)
        let attachmentID = try container.decode(TerminalAttachmentID.self, forKey: .attachmentID)
        let payloadLength = try container.decode(Int.self, forKey: .payloadLength)
        let sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence)
        guard let value = Self(
            version: version,
            sessionID: sessionID,
            attachmentID: attachmentID,
            payloadLength: payloadLength,
            sequence: sequence
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .payloadLength,
                in: container,
                debugDescription: "payloadLength must be non-negative."
            )
        }
        self = value
    }
}
