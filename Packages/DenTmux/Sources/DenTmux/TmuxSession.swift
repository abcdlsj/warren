import Foundation

public struct TmuxSession: Identifiable, Equatable, Sendable {
    public var id: String { sessionId }
    public let sessionId: String
    public let name: String
    public let windowCount: Int
    public let isAttached: Bool
    public var windows: [TmuxWindow]

    public init(
        sessionId: String,
        name: String,
        windowCount: Int = 0,
        isAttached: Bool = false,
        windows: [TmuxWindow] = []
    ) {
        self.sessionId = sessionId
        self.name = name
        self.windowCount = windowCount
        self.isAttached = isAttached
        self.windows = windows
    }

    public var isDenSession: Bool {
        SessionNaming.isDenSession(name)
    }

    public var projectShortName: String? {
        SessionNaming.parse(name)?.projectShortName
    }

    public var branchSlug: String? {
        SessionNaming.parse(name)?.branchSlug
    }
}
