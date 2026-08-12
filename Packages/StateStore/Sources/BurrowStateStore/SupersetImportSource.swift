import Foundation
import GRDB

public actor SupersetImportSource {
    public let databaseURL: URL
    private let database: DatabaseQueue
    private let pathInspector: any SupersetImportPathInspecting

    public init(
        databaseURL: URL,
        pathInspector: any SupersetImportPathInspecting = LocalSupersetImportPathInspector()
    ) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else {
            throw SupersetImportSourceError.sourceMissing(path: self.databaseURL.path)
        }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = false
        configuration.label = "Burrow.SupersetImport.ReadOnly"
        do {
            database = try DatabaseQueue(
                path: self.databaseURL.path,
                configuration: configuration
            )
        } catch {
            throw SupersetImportSourceError.sourceOpenFailed(
                path: self.databaseURL.path,
                reason: String(describing: error)
            )
        }
        self.pathInspector = pathInspector
    }

    public func preview() async throws -> SupersetImportPreview {
        do {
            return try await database.read { database in
                try Self.validateSchema(database)
                let schemaVersion = try Int.fetchOne(database, sql: "PRAGMA user_version")
                let projectRows = try Row.fetchAll(
                    database,
                    sql: """
                    SELECT id, name, main_repo_path
                    FROM projects
                    ORDER BY COALESCE(tab_order, 2147483647), last_opened_at DESC, id
                    """
                )
                let worktreeRows = try Row.fetchAll(
                    database,
                    sql: "SELECT id, project_id, path, branch FROM worktrees"
                )
                let workspaceRows = try Row.fetchAll(
                    database,
                    sql: """
                    SELECT id, project_id, worktree_id, type, branch, name, tab_order
                    FROM workspaces
                    WHERE deleting_at IS NULL
                    ORDER BY tab_order, id
                    """
                )

                let worktreesByID: [String: SourceWorktree] = Dictionary(
                    uniqueKeysWithValues: worktreeRows.map { row in
                        let worktree = SourceWorktree(
                            id: row["id"],
                            projectID: row["project_id"],
                            path: row["path"],
                            branch: row["branch"]
                        )
                        return (worktree.id, worktree)
                    }
                )
                let sourceWorkspaces: [SourceWorkspace] = workspaceRows.map { row in
                    SourceWorkspace(
                        id: row["id"],
                        projectID: row["project_id"],
                        worktreeID: row["worktree_id"],
                        type: row["type"],
                        branch: row["branch"],
                        name: row["name"]
                    )
                }

                let projects = projectRows.map { row -> SupersetImportProjectCandidate in
                    let sourceID: String = row["id"]
                    let sourceName: String = row["name"]
                    let sourcePath: String = row["main_repo_path"]
                    let projectPath = pathInspector.normalizedExistingDirectory(at: sourcePath)
                    let projectIsGit = projectPath.map(pathInspector.isGitWorktree(at:)) ?? false
                    let projectStatus: SupersetImportCandidateStatus = projectPath == nil
                        ? .missing
                        : (projectIsGit ? .ready : .invalid)
                    let projectDiagnostic: String? = switch projectStatus {
                    case .ready: nil
                    case .missing: "Repository directory does not exist."
                    case .invalid: "Repository path is not a Git worktree."
                    }

                    var candidates: [SupersetImportWorkspaceCandidate] = []
                    var seenPaths: Set<String> = []
                    func appendCandidate(
                        sourceWorkspaceID: String?,
                        sourceWorktreeID: String?,
                        name: String,
                        path: String,
                        branch: String?,
                        kind: String
                    ) {
                        let normalized = pathInspector.normalizedExistingDirectory(at: path)
                        let status: SupersetImportCandidateStatus
                        let diagnostic: String?
                        if let normalized {
                            if seenPaths.contains(normalized) {
                                return
                            }
                            seenPaths.insert(normalized)
                            if pathInspector.isGitWorktree(at: normalized) {
                                status = .ready
                                diagnostic = nil
                            } else {
                                status = .invalid
                                diagnostic = "Workspace path is not a Git worktree."
                            }
                        } else {
                            status = .missing
                            diagnostic = "Workspace directory does not exist."
                        }
                        let stablePath = normalized ?? URL(fileURLWithPath: path).standardizedFileURL.path
                        candidates.append(
                            SupersetImportWorkspaceCandidate(
                                id: sourceWorkspaceID ?? sourceWorktreeID ?? "main:\(sourceID)",
                                sourceWorkspaceID: sourceWorkspaceID,
                                sourceWorktreeID: sourceWorktreeID,
                                sourceProjectID: sourceID,
                                name: name,
                                path: stablePath,
                                branch: branch,
                                kind: kind,
                                status: status,
                                diagnostic: diagnostic
                            )
                        )
                    }

                    let rowsForProject = sourceWorkspaces.filter { $0.projectID == sourceID }
                    for workspace in rowsForProject {
                        if let worktreeID = workspace.worktreeID,
                           let worktree = worktreesByID[worktreeID] {
                            appendCandidate(
                                sourceWorkspaceID: workspace.id,
                                sourceWorktreeID: worktree.id,
                                name: workspace.name,
                                path: worktree.path,
                                branch: workspace.branch.isEmpty ? worktree.branch : workspace.branch,
                                kind: "worktree"
                            )
                        } else {
                            appendCandidate(
                                sourceWorkspaceID: workspace.id,
                                sourceWorktreeID: nil,
                                name: workspace.name,
                                path: sourcePath,
                                branch: workspace.branch,
                                kind: "main_checkout"
                            )
                        }
                    }
                    if candidates.isEmpty {
                        appendCandidate(
                            sourceWorkspaceID: nil,
                            sourceWorktreeID: nil,
                            name: sourceName,
                            path: sourcePath,
                            branch: nil,
                            kind: "main_checkout"
                        )
                    }

                    return SupersetImportProjectCandidate(
                        sourceProjectID: sourceID,
                        name: sourceName,
                        repositoryPath: projectPath ?? URL(fileURLWithPath: sourcePath).standardizedFileURL.path,
                        status: projectStatus,
                        diagnostic: projectDiagnostic,
                        workspaces: candidates
                    )
                }
                return SupersetImportPreview(
                    sourcePath: databaseURL.path,
                    schemaVersion: schemaVersion,
                    projects: projects
                )
            }
        } catch let error as SupersetImportSourceError {
            throw error
        } catch {
            throw SupersetImportSourceError.readFailed(
                path: databaseURL.path,
                reason: String(describing: error)
            )
        }
    }

    private static func validateSchema(_ database: Database) throws {
        let requirements: [String: Set<String>] = [
            "projects": ["id", "name", "main_repo_path", "tab_order", "last_opened_at"],
            "worktrees": ["id", "project_id", "path", "branch"],
            "workspaces": [
                "id", "project_id", "worktree_id", "type", "branch", "name",
                "tab_order", "deleting_at",
            ],
        ]
        var missing: [String] = []
        for (table, requiredColumns) in requirements {
            guard try database.tableExists(table) else {
                missing.append(table)
                continue
            }
            let columns = Set(try database.columns(in: table).map(\.name))
            for column in requiredColumns.subtracting(columns).sorted() {
                missing.append("\(table).\(column)")
            }
        }
        guard missing.isEmpty else {
            throw SupersetImportSourceError.incompatibleSchema(missing: missing.sorted())
        }
    }
}

private struct SourceWorktree {
    let id: String
    let projectID: String
    let path: String
    let branch: String
}

private struct SourceWorkspace {
    let id: String
    let projectID: String
    let worktreeID: String?
    let type: String
    let branch: String
    let name: String
}
