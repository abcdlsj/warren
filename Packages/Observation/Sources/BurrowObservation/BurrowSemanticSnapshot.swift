import Foundation

public struct BurrowSemanticRect: Codable, Hashable, Sendable {
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

public enum BurrowSemanticRole: String, Codable, Hashable, Sendable {
    case application
    case window
    case group
    case button
    case tab
    case terminal
    case text
}

public struct BurrowSemanticNode: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let role: BurrowSemanticRole
    public let label: String
    public let value: String?
    public let isEnabled: Bool
    public let isSelected: Bool
    public let isFocused: Bool
    public let frame: BurrowSemanticRect

    public init(
        id: String,
        role: BurrowSemanticRole,
        label: String,
        value: String? = nil,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        isFocused: Bool = false,
        frame: BurrowSemanticRect
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

public struct BurrowSemanticSnapshot: Codable, Hashable, Sendable {
    public let capturedAtNanoseconds: UInt64
    public let nodes: [BurrowSemanticNode]

    public init(capturedAtNanoseconds: UInt64, nodes: [BurrowSemanticNode]) {
        self.capturedAtNanoseconds = capturedAtNanoseconds
        self.nodes = nodes.sorted {
            if $0.id == $1.id {
                if $0.frame.y == $1.frame.y { return $0.frame.x < $1.frame.x }
                return $0.frame.y < $1.frame.y
            }
            return $0.id < $1.id
        }
    }

    public func node(id: String) -> BurrowSemanticNode? {
        nodes.first { $0.id == id }
    }
}
