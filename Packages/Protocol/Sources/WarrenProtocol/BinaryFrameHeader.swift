import WarrenDomain

/// PTY bytes are carried separately; this header never contains the payload.
public struct BinaryOutputFrameHeader: Codable, Hashable, Sendable {
    public let sessionID: TerminalSessionID
    public let epoch: UInt64
    public let sequence: UInt64
    public let payloadLength: Int

    public init?(sessionID: TerminalSessionID, epoch: UInt64, sequence: UInt64, payloadLength: Int) {
        guard payloadLength >= 0 else { return nil }
        self.sessionID = sessionID
        self.epoch = epoch
        self.sequence = sequence
        self.payloadLength = payloadLength
    }

    private enum CodingKeys: String, CodingKey { case sessionID, epoch, sequence, payloadLength }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sessionID = try container.decode(TerminalSessionID.self, forKey: .sessionID)
        let epoch = try container.decode(UInt64.self, forKey: .epoch)
        let sequence = try container.decode(UInt64.self, forKey: .sequence)
        let payloadLength = try container.decode(Int.self, forKey: .payloadLength)
        guard let value = Self(sessionID: sessionID, epoch: epoch, sequence: sequence, payloadLength: payloadLength) else {
            throw DecodingError.dataCorruptedError(forKey: .payloadLength, in: container,
                                                   debugDescription: "payloadLength must be non-negative.")
        }
        self = value
    }
}
