import Foundation

public struct WarrenDesktopEndpointOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let isLocal: Bool

    public init(id: String, label: String, isLocal: Bool = false) {
        self.id = id
        self.label = label
        self.isLocal = isLocal
    }
}

