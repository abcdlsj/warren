import Foundation
import GRDB
import DenCore

public struct ProjectRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "project"

    public var id: String
    public var name: String
    public var shortName: String
    public var repoRootPath: String
    public var gitCommonDir: String
    public var originURL: String?
    public var iconName: String?
    public var isFavorite: Bool
    public var isCollapsed: Bool
    public var lastActiveAt: Date?

    public init(from project: Project) {
        self.id = project.id.uuidString
        self.name = project.name
        self.shortName = project.shortName
        self.repoRootPath = project.repoRootPath
        self.gitCommonDir = project.gitCommonDir
        self.originURL = project.originURL
        self.iconName = project.iconName
        self.isFavorite = project.isFavorite
        self.isCollapsed = project.isCollapsed
        self.lastActiveAt = project.lastActiveAt
    }

    public func toModel() -> Project? {
        guard let uuid = UUID(uuidString: id) else {
            return nil
        }
        return Project(
            id: uuid,
            name: name,
            shortName: shortName,
            repoRootPath: repoRootPath,
            gitCommonDir: gitCommonDir,
            originURL: originURL,
            iconName: iconName,
            isFavorite: isFavorite,
            isCollapsed: isCollapsed,
            lastActiveAt: lastActiveAt
        )
    }
}
