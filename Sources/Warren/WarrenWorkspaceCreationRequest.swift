import Foundation

struct WorkspaceCreationRequest: Hashable, Sendable {
    let requestID: UUID
    let displayName: String
    let branch: String
    let path: String

    init(
        requestID: UUID = UUID(),
        displayName: String? = nil,
        branch: String,
        path: String = ""
    ) {
        self.requestID = requestID
        let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = normalizedName?.isEmpty == false ? normalizedName! : normalizedBranch
        self.branch = normalizedBranch
        self.path = path
    }
}
