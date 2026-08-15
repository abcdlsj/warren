import Foundation

public struct WarrenDesktopEndpointOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let isLocal: Bool
    public let detail: String?

    public init(id: String, label: String, isLocal: Bool = false, detail: String? = nil) {
        self.id = id
        self.label = label
        self.isLocal = isLocal
        self.detail = detail
    }
}
