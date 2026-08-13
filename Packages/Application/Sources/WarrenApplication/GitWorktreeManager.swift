import Foundation

public struct GitWorktreeCreation: Hashable, Sendable {
    public let repositoryPath: String
    public let worktreePath: String
    public let branch: String

    public init(repositoryPath: String, worktreePath: String, branch: String) {
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
        self.branch = branch
    }
}

public protocol GitWorktreeManaging: Sendable {
    func create(_ request: GitWorktreeCreation) async throws
    func remove(_ request: GitWorktreeCreation) async throws
}

public struct LocalGitWorktreeManager: GitWorktreeManaging {
    public init() {}

    public func create(_ request: GitWorktreeCreation) async throws {
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: request.worktreePath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw WarrenApplicationError.gitWorktree(String(describing: error))
        }
        try await run([
            "-C", request.repositoryPath,
            "worktree", "add", "-b", request.branch, request.worktreePath,
        ])
    }

    public func remove(_ request: GitWorktreeCreation) async throws {
        try await run([
            "-C", request.repositoryPath,
            "worktree", "remove", "--force", request.worktreePath,
        ])
    }

    private func run(_ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            let stderr = Pipe()
            process.standardOutput = Pipe()
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                throw WarrenApplicationError.gitWorktree(String(describing: error))
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(
                    decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                throw WarrenApplicationError.gitWorktree(
                    detail.isEmpty ? "git exited with status \(process.terminationStatus)." : detail
                )
            }
        }.value
    }
}

public struct WorkspaceCreationRequest: Hashable, Sendable {
    public let requestID: UUID
    public let displayName: String
    public let branch: String
    public let path: String

    public init(
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
