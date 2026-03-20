import Foundation

public struct Project: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var shortName: String
    public var repoRootPath: String
    public var gitCommonDir: String
    public var originURL: String?
    public var iconName: String?
    public var isFavorite: Bool
    public var isCollapsed: Bool
    public var lastActiveAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        shortName: String? = nil,
        repoRootPath: String,
        gitCommonDir: String = "",
        originURL: String? = nil,
        iconName: String? = nil,
        isFavorite: Bool = false,
        isCollapsed: Bool = false,
        lastActiveAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName ?? Self.autoShortName(from: name)
        self.repoRootPath = repoRootPath
        self.gitCommonDir = gitCommonDir
        self.originURL = originURL
        self.iconName = iconName
        self.isFavorite = isFavorite
        self.isCollapsed = isCollapsed
        self.lastActiveAt = lastActiveAt
    }

    public static func autoShortName(from name: String) -> String {
        let lower = name.lowercased()
        if lower.count <= 8 { return lower }
        let parts = lower.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " || $0 == "." })
        let initials = String(parts.compactMap(\.first))
        return initials.isEmpty ? String(lower.prefix(8)) : initials
    }
}
