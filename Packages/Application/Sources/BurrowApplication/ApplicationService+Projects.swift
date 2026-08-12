import BurrowDomain
import Foundation

extension BurrowApplicationService {
    /// Returns one workspace from the Host-owned projection.
    ///
    /// Workspace creation/removal is deliberately not inferred from this
    /// query.  A Workspace points at a real directory and, for Git worktrees,
    /// its lifecycle must be backed by an explicit Git operation.  Until that
    /// adapter exists, the application exposes read/query behavior only.
    public func workspace(id: WorkspaceID) async throws -> Workspace {
        try requireReady()
        guard let workspace = state.workspaces.first(where: { $0.id == id }) else {
            throw BurrowApplicationError.workspaceNotFound(id)
        }
        return workspace
    }

    /// Returns workspaces owned by one project in persisted order.
    public func workspaces(projectID: ProjectID) async throws -> [Workspace] {
        try requireReady()
        guard state.projects.contains(where: { $0.id == projectID }) else {
            throw BurrowApplicationError.projectNotFound(projectID)
        }
        return state.workspaces.filter { $0.projectID == projectID }
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
                    throw BurrowApplicationError.projectAlreadyExists(normalized)
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
            throw BurrowApplicationError.projectNotFound(projectID)
        }
        guard let workspace = state.workspaces.first(where: {
            $0.projectID == project.id && normalizeStoredPath($0.path) == normalizeStoredPath(project.rootPath)
        }) else {
            throw BurrowApplicationError.projectWorkspaceMissing(projectID)
        }
        return workspace
    }

    public func normalizeProjectPath(_ path: String) throws -> String {
        try normalizeFolder(path)
    }

    internal func normalizeFolder(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BurrowApplicationError.projectPathInvalid(path)
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
            throw BurrowApplicationError.projectPathInvalid(path)
        }
        return url.path
    }

    internal func normalizeStoredPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
