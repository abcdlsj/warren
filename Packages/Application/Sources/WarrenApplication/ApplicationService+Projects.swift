import WarrenDomain
import WarrenStateStore
import Foundation

extension WarrenApplicationService {
    /// Returns one workspace from the Host-owned projection.
    ///
    /// Workspace creation/removal is deliberately not inferred from this
    /// query.  A Workspace points at a real directory and, for Git worktrees,
    /// its lifecycle must be backed by an explicit Git operation.  Until that
    /// adapter exists, the application exposes read/query behavior only.
    public func workspace(id: WorkspaceID) async throws -> Workspace {
        try requireReady()
        guard let workspace = state.workspaces.first(where: { $0.id == id }) else {
            throw WarrenApplicationError.workspaceNotFound(id)
        }
        return workspace
    }

    /// Returns workspaces owned by one project in persisted order.
    public func workspaces(projectID: ProjectID) async throws -> [Workspace] {
        try requireReady()
        guard state.projects.contains(where: { $0.id == projectID }) else {
            throw WarrenApplicationError.projectNotFound(projectID)
        }
        return state.workspaces.filter { $0.projectID == projectID }
    }

    /// Creates a new Git worktree and only then publishes it as a Workspace.
    /// If persistence fails, the adapter removes the just-created worktree so
    /// Git and Warren cannot disagree about ownership.
    public func createWorkspace(
        projectID: ProjectID,
        request: WorkspaceCreationRequest
    ) async throws -> Workspace {
        do {
            let workspace = try await withPersistenceMutation {
                try requireReady()
                if let receipt = state.requestReceipts.first(where: {
                    $0.requestID == request.requestID && $0.commandKind == "create_workspace"
                }), let workspaceID = WorkspaceID(uuidString: receipt.resourceID),
                   let workspace = state.workspaces.first(where: { $0.id == workspaceID }) {
                    return workspace
                }
                guard let project = state.projects.first(where: { $0.id == projectID }) else {
                    throw WarrenApplicationError.projectNotFound(projectID)
                }
                let branch = request.branch.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isValidBranchName(branch) else {
                    throw WarrenApplicationError.workspaceBranchInvalid(branch)
                }
                let path = try normalizeNewWorkspacePath(request.path)
                guard !state.workspaces.contains(where: {
                    normalizeStoredPath($0.path) == path
                }) else {
                    throw WarrenApplicationError.workspacePathAlreadyExists(path)
                }
                let creation = GitWorktreeCreation(
                    repositoryPath: project.rootPath,
                    worktreePath: path,
                    branch: branch
                )
                try await gitWorktreeManager.create(creation)
                let workspace = Workspace(
                    projectID: project.id,
                    name: branch,
                    path: path,
                    branch: branch
                )
                var candidate = state
                candidate.workspaces.append(workspace)
                candidate.requestReceipts.append(PersistedRequestReceipt(
                    requestID: request.requestID,
                    commandKind: "create_workspace",
                    resourceID: workspace.id.description,
                    completedAt: clock()
                ))
                do {
                    try await save(candidate)
                } catch {
                    try? await gitWorktreeManager.remove(creation)
                    throw error
                }
                mergePendingSequences(into: &candidate)
                state = candidate
                return workspace
            }
            try await layoutStore.selectWorkspace(workspace.id, in: windowID)
            await publish()
            return workspace
        } catch {
            let appError = error.asApplicationError
            report(appError, id: "workspace.create.\(projectID)")
            await publish()
            throw appError
        }
    }

    /// Adds one local folder and its root Workspace as one serialized state
    /// mutation. Symlinks and spelling differences resolve to one project.
    public func addProject(path: String) async throws -> Project {
        do {
            let project = try await withPersistenceMutation {
                try requireReady()
                let normalized = try normalizeFolder(path)
                guard !state.projects.contains(where: {
                    normalizeStoredPath($0.rootPath) == normalized
                }) else {
                    throw WarrenApplicationError.projectAlreadyExists(normalized)
                }

                let project = Project(
                    hostID: host.id,
                    name: URL(fileURLWithPath: normalized).lastPathComponent,
                    rootPath: normalized
                )
                let branch = await gitMetadataReader.branch(at: normalized)
                let workspace = Workspace(
                    projectID: project.id,
                    name: branch?.isEmpty == false ? branch! : "main",
                    path: normalized,
                    branch: branch
                )
                var candidate = state
                candidate.projects.append(project)
                candidate.workspaces.append(workspace)
                try await save(candidate)
                mergePendingSequences(into: &candidate)
                state = candidate
                return project
            }
            await publish()
            return project
        } catch {
            let appError = error.asApplicationError
            report(appError, id: "project.add")
            await publish()
            throw appError
        }
    }

    public func addProject(folder: URL) async throws -> Project {
        try await addProject(path: folder.path)
    }

    public func addProject(_ folder: URL) async throws -> Project {
        try await addProject(folder: folder)
    }

    public func rootWorkspace(for projectID: ProjectID) async throws -> Workspace {
        try requireReady()
        guard let project = state.projects.first(where: { $0.id == projectID }) else {
            throw WarrenApplicationError.projectNotFound(projectID)
        }
        guard let workspace = state.workspaces.first(where: {
            $0.projectID == project.id && normalizeStoredPath($0.path) == normalizeStoredPath(project.rootPath)
        }) else {
            throw WarrenApplicationError.projectWorkspaceMissing(projectID)
        }
        return workspace
    }

    public func normalizeProjectPath(_ path: String) throws -> String {
        try normalizeFolder(path)
    }

    internal func normalizeFolder(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WarrenApplicationError.projectPathInvalid(path)
        }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw WarrenApplicationError.projectPathInvalid(path)
        }
        return url.path
    }

    internal func normalizeStoredPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func normalizeNewWorkspacePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WarrenApplicationError.projectPathInvalid(path)
        }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func isValidBranchName(_ branch: String) -> Bool {
        guard !branch.isEmpty,
              !branch.hasPrefix("-"),
              !branch.hasSuffix("."),
              !branch.hasSuffix("/"),
              !branch.contains(".."),
              !branch.contains("@{"),
              !branch.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7f || " ~^:?*[\\".unicodeScalars.contains($0)
              }) else { return false }
        return true
    }
}
