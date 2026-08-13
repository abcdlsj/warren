import Foundation
import WarrenDomain

public struct AttachedMessage: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let sessionID: TerminalSessionID
    public let attachmentID: TerminalAttachmentID
    public let epoch: UInt64
    public let sequence: UInt64
    public let capabilities: ProtocolCapabilities
    public let controllerAttachmentID: TerminalAttachmentID?

    public init(version: ProtocolVersion = .current, sessionID: TerminalSessionID,
                attachmentID: TerminalAttachmentID, epoch: UInt64, sequence: UInt64,
                capabilities: ProtocolCapabilities = .core,
                controllerAttachmentID: TerminalAttachmentID? = nil) {
        self.version = version
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.epoch = epoch
        self.sequence = sequence
        self.capabilities = capabilities
        self.controllerAttachmentID = controllerAttachmentID
    }
}

public struct ExitMessage: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let sessionID: TerminalSessionID
    public let epoch: UInt64
    public let sequence: UInt64
    public let exitCode: Int?
    public let reason: String?

    public init(version: ProtocolVersion = .current, sessionID: TerminalSessionID,
                epoch: UInt64, sequence: UInt64, exitCode: Int? = nil, reason: String? = nil) {
        self.version = version
        self.sessionID = sessionID
        self.epoch = epoch
        self.sequence = sequence
        self.exitCode = exitCode
        self.reason = reason
    }
}

public struct TitleMessage: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let sessionID: TerminalSessionID
    public let title: String

    public init(version: ProtocolVersion = .current, sessionID: TerminalSessionID, title: String) {
        self.version = version
        self.sessionID = sessionID
        self.title = title
    }
}

public struct RuntimeMetadataMessage: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let sessionID: TerminalSessionID
    public let process: String
    public let workingDirectory: String

    public init(
        version: ProtocolVersion = .current,
        sessionID: TerminalSessionID,
        process: String,
        workingDirectory: String
    ) {
        self.version = version
        self.sessionID = sessionID
        self.process = process
        self.workingDirectory = workingDirectory
    }
}

public struct SyncedMessage: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let sessionID: TerminalSessionID
    public let epoch: UInt64
    public let sequence: UInt64

    public init(version: ProtocolVersion = .current, sessionID: TerminalSessionID,
                epoch: UInt64, sequence: UInt64) {
        self.version = version
        self.sessionID = sessionID
        self.epoch = epoch
        self.sequence = sequence
    }

    public init(version: ProtocolVersion = .current, sessionID: TerminalSessionID,
                anchor: RecoveryAnchor) {
        self.init(version: version, sessionID: sessionID, epoch: anchor.epoch, sequence: anchor.sequence)
    }

    public var anchor: RecoveryAnchor { RecoveryAnchor(epoch: epoch, sequence: sequence) }
}

public struct ControlChangedMessage: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let sessionID: TerminalSessionID
    public let controllerAttachmentID: TerminalAttachmentID?
    public let leaseID: ControlLeaseID?

    public init(version: ProtocolVersion = .current, sessionID: TerminalSessionID,
                controllerAttachmentID: TerminalAttachmentID?, leaseID: ControlLeaseID? = nil) {
        self.version = version
        self.sessionID = sessionID
        self.controllerAttachmentID = controllerAttachmentID
        self.leaseID = leaseID
    }
}

public enum ServerControlMessage: Codable, Hashable, Sendable {
    case attached(AttachedMessage)
    case error(ProtocolError)
    case exit(ExitMessage)
    case title(TitleMessage)
    case runtimeMetadata(RuntimeMetadataMessage)
    case synced(SyncedMessage)
    case controlChanged(ControlChangedMessage)

    public var version: ProtocolVersion {
        switch self {
        case .attached(let value): return value.version
        case .error(let value): return value.version
        case .exit(let value): return value.version
        case .title(let value): return value.version
        case .runtimeMetadata(let value): return value.version
        case .synced(let value): return value.version
        case .controlChanged(let value): return value.version
        }
    }

    private enum CodingKeys: String, CodingKey { case type, payload }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .attached(let value):
            try container.encode("attached", forKey: .type)
            try container.encode(value, forKey: .payload)
        case .error(let value):
            try container.encode("error", forKey: .type)
            try container.encode(value, forKey: .payload)
        case .exit(let value):
            try container.encode("exit", forKey: .type)
            try container.encode(value, forKey: .payload)
        case .title(let value):
            try container.encode("title", forKey: .type)
            try container.encode(value, forKey: .payload)
        case .runtimeMetadata(let value):
            try container.encode("runtime_metadata", forKey: .type)
            try container.encode(value, forKey: .payload)
        case .synced(let value):
            try container.encode("synced", forKey: .type)
            try container.encode(value, forKey: .payload)
        case .controlChanged(let value):
            try container.encode("control_changed", forKey: .type)
            try container.encode(value, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "attached": self = .attached(try container.decode(AttachedMessage.self, forKey: .payload))
        case "error": self = .error(try container.decode(ProtocolError.self, forKey: .payload))
        case "exit": self = .exit(try container.decode(ExitMessage.self, forKey: .payload))
        case "title": self = .title(try container.decode(TitleMessage.self, forKey: .payload))
        case "runtime_metadata": self = .runtimeMetadata(
            try container.decode(RuntimeMetadataMessage.self, forKey: .payload)
        )
        case "synced": self = .synced(try container.decode(SyncedMessage.self, forKey: .payload))
        case "control_changed": self = .controlChanged(try container.decode(ControlChangedMessage.self, forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                   debugDescription: "Unknown server control message type.")
        }
    }
}
