import Foundation

public struct GitStatusInfo: Equatable, Sendable {
    public var isDirty: Bool {
        stagedCount > 0 || modifiedCount > 0 || untrackedCount > 0
    }

    public let untrackedCount: Int
    public let modifiedCount: Int
    public let stagedCount: Int
    public let ahead: Int
    public let behind: Int
    public let branch: String?
    public let upstream: String?

    public init(
        untrackedCount: Int = 0,
        modifiedCount: Int = 0,
        stagedCount: Int = 0,
        ahead: Int = 0,
        behind: Int = 0,
        branch: String? = nil,
        upstream: String? = nil
    ) {
        self.untrackedCount = untrackedCount
        self.modifiedCount = modifiedCount
        self.stagedCount = stagedCount
        self.ahead = ahead
        self.behind = behind
        self.branch = branch
        self.upstream = upstream
    }

    public static let clean = GitStatusInfo()
}
