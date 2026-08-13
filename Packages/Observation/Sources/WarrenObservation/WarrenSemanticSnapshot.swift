import Foundation

public struct WarrenSemanticRect: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum WarrenSemanticRole: String, Codable, Hashable, Sendable {
    case application
    case window
    case group
    case button
    case tab
    case terminal
    case text
}

public struct WarrenSemanticNode: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let role: WarrenSemanticRole
    public let label: String
    public let value: String?
    public let isEnabled: Bool
    public let isSelected: Bool
    public let isFocused: Bool
    public let frame: WarrenSemanticRect

    public init(
        id: String,
        role: WarrenSemanticRole,
        label: String,
        value: String? = nil,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        isFocused: Bool = false,
        frame: WarrenSemanticRect
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.frame = frame
    }
}

public struct WarrenSemanticSnapshot: Codable, Hashable, Sendable {
    public let capturedAtNanoseconds: UInt64
    public let nodes: [WarrenSemanticNode]

    public init(capturedAtNanoseconds: UInt64, nodes: [WarrenSemanticNode]) {
        self.capturedAtNanoseconds = capturedAtNanoseconds
        self.nodes = nodes.sorted {
            if $0.id == $1.id {
                if $0.frame.y == $1.frame.y { return $0.frame.x < $1.frame.x }
                return $0.frame.y < $1.frame.y
            }
            return $0.id < $1.id
        }
    }

    public func node(id: String) -> WarrenSemanticNode? {
        nodes.first { $0.id == id }
    }
}
