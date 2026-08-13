import Foundation
import WarrenDomain

/// The durable part of a Terminal Session needed to recover it after a Host
/// restart.  Attachments, leases, and client layout are deliberately absent.
public struct PersistedTerminalSession: Identifiable, Codable, Hashable, Sendable {
    public let id: TerminalSessionID
    public let workspaceID: WorkspaceID
    public var epoch: UInt64
    public var sequence: UInt64
    public var workingDirectory: String
    public var terminalSize: TerminalSize
    public var runtimeAdoptionDescriptor: RuntimeAdoptionDescriptor?
    public var kind: TerminalSessionKind
    public var agentSessionID: String?
    public var title: String?
    public var lifecycle: TerminalSessionLifecycle
    public var endedAt: Date?

    public init(
        id: TerminalSessionID = TerminalSessionID(),
        workspaceID: WorkspaceID,
        epoch: UInt64 = 0,
        sequence: UInt64 = 0,
        workingDirectory: String,
        terminalSize: TerminalSize,
        runtimeAdoptionDescriptor: RuntimeAdoptionDescriptor? = nil,
        kind: TerminalSessionKind = .shell,
        agentSessionID: String? = nil,
        title: String? = nil,
        lifecycle: TerminalSessionLifecycle = .running,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.epoch = epoch
        self.sequence = sequence
        self.workingDirectory = workingDirectory
        self.terminalSize = terminalSize
        self.runtimeAdoptionDescriptor = runtimeAdoptionDescriptor
        self.kind = kind
        self.agentSessionID = agentSessionID
        self.title = title
        self.lifecycle = lifecycle
        self.endedAt = endedAt
    }

    /// Reconstructs the domain session while keeping runtime details at the
    /// persistence boundary.
    public var terminalSession: TerminalSession {
        TerminalSession(
            id: id,
            workspaceID: workspaceID,
            epoch: epoch,
            sequence: sequence
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceID
        case epoch
        case sequence
        case workingDirectory
        case terminalSize
        case runtimeAdoptionDescriptor
        case kind
        case agentSessionID
        case title
        case lifecycle
        case endedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TerminalSessionID.self, forKey: .id)
        workspaceID = try container.decode(WorkspaceID.self, forKey: .workspaceID)
        epoch = try container.decode(UInt64.self, forKey: .epoch)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        let sizePayload = try container.decode(SizePayload.self, forKey: .terminalSize)
        let columns = sizePayload.columns
        let rows = sizePayload.rows
        guard let terminalSize = TerminalSize(columns: columns, rows: rows) else {
            throw DecodingError.dataCorruptedError(
                forKey: .terminalSize,
                in: container,
                debugDescription: "TerminalSize columns and rows must be positive."
            )
        }
        self.terminalSize = terminalSize
        runtimeAdoptionDescriptor = try container.decodeIfPresent(
            RuntimeAdoptionDescriptor.self,
            forKey: .runtimeAdoptionDescriptor
        )
        kind = try container.decodeIfPresent(
            TerminalSessionKind.self,
            forKey: .kind
        ) ?? .shell
        agentSessionID = try container.decodeIfPresent(String.self, forKey: .agentSessionID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        lifecycle = try container.decodeIfPresent(
            TerminalSessionLifecycle.self,
            forKey: .lifecycle
        ) ?? .running
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
    }

    private struct SizePayload: Decodable {
        let columns: Int
        let rows: Int
    }
}
