import WarrenClientCore
import WarrenDomain
import Foundation
import GRDB

/// The production Host store.
///
/// Resource relationships are represented by SQLite foreign keys. Runtime
/// metadata remains JSON because it is an opaque adapter descriptor, not a
/// queryable Host resource. Saving replaces one complete application snapshot
/// in a single transaction, preserving the current repository contract while
/// the application migrates to finer-grained commands.
public actor SQLiteHostStateRepository: HostStateRepository, SupersetImportCommitting, ClientLayoutRepository {
    public let databaseURL: URL
    private let database: DatabaseQueue

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        let directory = self.databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw HostStateRepositoryError.directoryCreationFailed(
                path: directory.path,
                reason: String(describing: error)
            )
        }

        var configuration = Configuration()
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
            try database.execute(sql: "PRAGMA journal_mode = WAL")
            try database.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        do {
            database = try DatabaseQueue(
                path: self.databaseURL.path,
                configuration: configuration
            )
            try Self.migrator.migrate(database)
        } catch {
            throw HostStateRepositoryError.databaseOpenFailed(
                path: self.databaseURL.path,
                reason: String(describing: error)
            )
        }
    }

    public func load() async throws -> PersistedHostState {
        do {
            return try await database.read { database in
                let hosts = try Row.fetchAll(
                    database,
                    sql: "SELECT id, name FROM hosts ORDER BY created_at, id"
                ).map { row in
                    Host(
                        id: try Self.domainID(row: row, table: "hosts", column: "id"),
                        name: row["name"]
                    )
                }

                let projects = try Row.fetchAll(
                    database,
                    sql: "SELECT id, host_id, name, repository_path FROM projects ORDER BY created_at, id"
                ).map { row in
                    Project(
                        id: try Self.domainID(row: row, table: "projects", column: "id"),
                        hostID: try Self.domainID(row: row, table: "projects", column: "host_id"),
                        name: row["name"],
                        rootPath: row["repository_path"]
                    )
                }

                let workspaces = try Row.fetchAll(
                    database,
                    sql: "SELECT id, project_id, name, path, branch FROM workspaces ORDER BY created_at, id"
                ).map { row in
                    Workspace(
                        id: try Self.domainID(row: row, table: "workspaces", column: "id"),
                        projectID: try Self.domainID(row: row, table: "workspaces", column: "project_id"),
                        name: row["name"],
                        path: row["path"],
                        branch: row["branch"]
                    )
                }

                let sessionRows = try Row.fetchAll(
                    database,
                    sql: """
                    SELECT s.id, s.workspace_id, s.epoch, s.sequence,
                           s.working_directory, s.columns, s.rows, s.kind,
                           s.title, s.lifecycle, s.ended_at,
                           r.adapter, r.runtime_identifier, r.metadata_json
                    FROM terminal_sessions s
                    LEFT JOIN runtime_bindings r ON r.session_id = s.id
                    ORDER BY s.created_at, s.id
                    """
                )
                let terminalSessions = try sessionRows.map { row in
                    let columns: Int = row["columns"]
                    let rows: Int = row["rows"]
                    guard let terminalSize = TerminalSize(columns: columns, rows: rows) else {
                        throw HostStateRepositoryError.invalidDatabaseValue(
                            table: "terminal_sessions",
                            column: "columns/rows",
                            value: "\(columns)x\(rows)"
                        )
                    }
                    let kindValue: String = row["kind"]
                    guard let kind = TerminalSessionKind(rawValue: kindValue) else {
                        throw HostStateRepositoryError.invalidDatabaseValue(
                            table: "terminal_sessions",
                            column: "kind",
                            value: kindValue
                        )
                    }
                    let adapter: String? = row["adapter"]
                    let runtimeIdentifier: String? = row["runtime_identifier"]
                    let metadataJSON: String? = row["metadata_json"]
                    let descriptor: RuntimeAdoptionDescriptor?
                    if let adapter, let runtimeIdentifier {
                        let metadata: [String: String]
                        if let metadataJSON {
                            do {
                                metadata = try JSONDecoder().decode(
                                    [String: String].self,
                                    from: Data(metadataJSON.utf8)
                                )
                            } catch {
                                throw HostStateRepositoryError.invalidDatabaseValue(
                                    table: "runtime_bindings",
                                    column: "metadata_json",
                                    value: metadataJSON
                                )
                            }
                        } else {
                            metadata = [:]
                        }
                        descriptor = RuntimeAdoptionDescriptor(
                            runtime: adapter,
                            identifier: runtimeIdentifier,
                            metadata: metadata
                        )
                    } else {
                        descriptor = nil
                    }
                    let epochString: String = row["epoch"]
                    let sequenceString: String = row["sequence"]
                    guard let epoch = UInt64(epochString) else {
                        throw HostStateRepositoryError.invalidDatabaseValue(
                            table: "terminal_sessions",
                            column: "epoch",
                            value: epochString
                        )
                    }
                    guard let sequence = UInt64(sequenceString) else {
                        throw HostStateRepositoryError.invalidDatabaseValue(
                            table: "terminal_sessions",
                            column: "sequence",
                            value: sequenceString
                        )
                    }
                    let lifecycleValue: String = row["lifecycle"]
                    guard let lifecycle = PersistedTerminalSessionLifecycle(rawValue: lifecycleValue) else {
                        throw HostStateRepositoryError.invalidDatabaseValue(
                            table: "terminal_sessions",
                            column: "lifecycle",
                            value: lifecycleValue
                        )
                    }
                    return PersistedTerminalSession(
                        id: try Self.domainID(row: row, table: "terminal_sessions", column: "id"),
                        workspaceID: try Self.domainID(
                            row: row,
                            table: "terminal_sessions",
                            column: "workspace_id"
                        ),
                        epoch: epoch,
                        sequence: sequence,
                        workingDirectory: row["working_directory"],
                        terminalSize: terminalSize,
                        runtimeAdoptionDescriptor: descriptor,
                        kind: kind,
                        title: row["title"],
                        lifecycle: lifecycle,
                        endedAt: row["ended_at"]
                    )
                }

                let requestReceipts = try Row.fetchAll(
                    database,
                    sql: """
                    SELECT request_id, command_kind, resource_id, completed_at
                    FROM request_receipts
                    ORDER BY completed_at, request_id
                    """
                ).map { row in
                    let rawRequestID: String = row["request_id"]
                    guard let requestID = UUID(uuidString: rawRequestID) else {
                        throw HostStateRepositoryError.invalidDatabaseValue(
                            table: "request_receipts",
                            column: "request_id",
                            value: rawRequestID
                        )
                    }
                    return PersistedRequestReceipt(
                        requestID: requestID,
                        commandKind: row["command_kind"],
                        resourceID: row["resource_id"],
                        completedAt: row["completed_at"]
                    )
                }

                return PersistedHostState(
                    hosts: hosts,
                    projects: projects,
                    workspaces: workspaces,
                    terminalSessions: terminalSessions,
                    requestReceipts: requestReceipts
                )
            }
        } catch let error as HostStateRepositoryError {
            throw error
        } catch {
            throw HostStateRepositoryError.databaseReadFailed(
                path: databaseURL.path,
                reason: String(describing: error)
            )
        }
    }

    public func save(_ state: PersistedHostState) async throws {
        try HostStateRepositoryError.validateSupportedSchema(state)
        do {
            try await database.write { database in
                try database.execute(sql: "DELETE FROM request_receipts")
                try database.execute(sql: "DELETE FROM runtime_bindings")
                try database.execute(sql: "DELETE FROM terminal_sessions")
                try database.execute(sql: "DELETE FROM workspaces")
                try database.execute(sql: "DELETE FROM projects")
                try database.execute(sql: "DELETE FROM hosts")

                for host in state.hosts {
                    try database.execute(
                        sql: "INSERT INTO hosts (id, name) VALUES (?, ?)",
                        arguments: [host.id.description, host.name]
                    )
                }
                for project in state.projects {
                    try database.execute(
                        sql: """
                        INSERT INTO projects (id, host_id, name, repository_path, repository_identity)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            project.id.description,
                            project.hostID.description,
                            project.name,
                            project.rootPath,
                            Self.normalizedPath(project.rootPath),
                        ]
                    )
                }
                for workspace in state.workspaces {
                    try database.execute(
                        sql: """
                        INSERT INTO workspaces (id, project_id, name, path, normalized_path, branch, kind)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            workspace.id.description,
                            workspace.projectID.description,
                            workspace.name,
                            workspace.path,
                            Self.normalizedPath(workspace.path),
                            workspace.branch,
                            workspace.path == state.projects.first(where: {
                                $0.id == workspace.projectID
                            })?.rootPath ? "main_checkout" : "worktree",
                        ]
                    )
                }
                for session in state.terminalSessions {
                    try database.execute(
                        sql: """
                        INSERT INTO terminal_sessions (
                            id, workspace_id, epoch, sequence, working_directory,
                            columns, rows, kind, title, lifecycle, ended_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            session.id.description,
                            session.workspaceID.description,
                            String(session.epoch),
                            String(session.sequence),
                            session.workingDirectory,
                            session.terminalSize.columns,
                            session.terminalSize.rows,
                            session.kind.rawValue,
                            session.title,
                            session.lifecycle.rawValue,
                            session.endedAt,
                        ]
                    )
                    if let descriptor = session.runtimeAdoptionDescriptor {
                        let metadata = try String(
                            decoding: JSONEncoder().encode(descriptor.metadata),
                            as: UTF8.self
                        )
                        try database.execute(
                            sql: """
                            INSERT INTO runtime_bindings (
                                session_id, adapter, runtime_identifier, metadata_json
                            ) VALUES (?, ?, ?, ?)
                            """,
                            arguments: [
                                session.id.description,
                                descriptor.runtime,
                                descriptor.identifier,
                                metadata,
                            ]
                        )
                    }
                }
                for receipt in state.requestReceipts {
                    try database.execute(
                        sql: """
                        INSERT INTO request_receipts (
                            request_id, command_kind, resource_id, completed_at
                        ) VALUES (?, ?, ?, ?)
                        """,
                        arguments: [
                            receipt.requestID.uuidString.lowercased(),
                            receipt.commandKind,
                            receipt.resourceID,
                            receipt.completedAt,
                        ]
                    )
                }
            }
        } catch {
            throw HostStateRepositoryError.databaseWriteFailed(
                path: databaseURL.path,
                reason: String(describing: error)
            )
        }
    }

    /// Atomically copies a read-only Superset preview into Warren-owned rows.
    /// Source identifiers are recorded only in the receipt summary; Warren
    /// resources always receive new domain IDs.
    public func importSuperset(
        _ preview: SupersetImportPreview,
        into hostID: HostID
    ) async throws -> SupersetImportCommitResult {
        let sourceIdentity = Self.normalizedPath(preview.sourcePath)
        do {
            return try await database.write { database in
                guard try Bool.fetchOne(
                    database,
                    sql: "SELECT EXISTS(SELECT 1 FROM hosts WHERE id = ?)",
                    arguments: [hostID.description]
                ) == true else {
                    throw HostStateRepositoryError.invalidDatabaseValue(
                        table: "hosts",
                        column: "id",
                        value: hostID.description
                    )
                }
                if try Bool.fetchOne(
                    database,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM import_receipts
                        WHERE source_kind = 'superset' AND source_identity = ?
                    )
                    """,
                    arguments: [sourceIdentity]
                ) == true {
                    return SupersetImportCommitResult(
                        importedProjectIDs: [],
                        importedWorkspaceIDs: [],
                        skippedProjectCount: preview.projects.count,
                        skippedWorkspaceCount: preview.projects.flatMap(\.workspaces).count,
                        wasAlreadyImported: true
                    )
                }

                var importedProjects: [String] = []
                var importedWorkspaces: [String] = []
                var skippedProjects = 0
                var skippedWorkspaces = 0

                for candidate in preview.projects {
                    guard candidate.status == .ready else {
                        skippedProjects += 1
                        skippedWorkspaces += candidate.workspaces.count
                        continue
                    }
                    let repositoryIdentity = Self.normalizedPath(candidate.repositoryPath)
                    let existingProjectID = try String.fetchOne(
                        database,
                        sql: """
                        SELECT id FROM projects
                        WHERE host_id = ? AND repository_identity = ?
                        """,
                        arguments: [hostID.description, repositoryIdentity]
                    )
                    let projectID: String
                    if let existingProjectID {
                        projectID = existingProjectID
                        skippedProjects += 1
                    } else {
                        projectID = ProjectID().description
                        try database.execute(
                            sql: """
                            INSERT INTO projects (
                                id, host_id, name, repository_path, repository_identity
                            ) VALUES (?, ?, ?, ?, ?)
                            """,
                            arguments: [
                                projectID,
                                hostID.description,
                                candidate.name,
                                candidate.repositoryPath,
                                repositoryIdentity,
                            ]
                        )
                        importedProjects.append(projectID)
                    }

                    for workspace in candidate.workspaces {
                        guard workspace.status == .ready else {
                            skippedWorkspaces += 1
                            continue
                        }
                        let normalizedPath = Self.normalizedPath(workspace.path)
                        if try Bool.fetchOne(
                            database,
                            sql: "SELECT EXISTS(SELECT 1 FROM workspaces WHERE normalized_path = ?)",
                            arguments: [normalizedPath]
                        ) == true {
                            skippedWorkspaces += 1
                            continue
                        }
                        let workspaceID = WorkspaceID().description
                        try database.execute(
                            sql: """
                            INSERT INTO workspaces (
                                id, project_id, name, path, normalized_path, branch, kind
                            ) VALUES (?, ?, ?, ?, ?, ?, ?)
                            """,
                            arguments: [
                                workspaceID,
                                projectID,
                                workspace.name,
                                workspace.path,
                                normalizedPath,
                                workspace.branch,
                                workspace.kind,
                            ]
                        )
                        importedWorkspaces.append(workspaceID)
                    }
                }

                let result = SupersetImportCommitResult(
                    importedProjectIDs: importedProjects,
                    importedWorkspaceIDs: importedWorkspaces,
                    skippedProjectCount: skippedProjects,
                    skippedWorkspaceCount: skippedWorkspaces,
                    wasAlreadyImported: false
                )
                let receiptSummary = try String(
                    decoding: JSONEncoder().encode(result),
                    as: UTF8.self
                )
                try database.execute(
                    sql: """
                    INSERT INTO import_receipts (
                        source_kind, source_identity, source_version, summary_json
                    ) VALUES ('superset', ?, ?, ?)
                    """,
                    arguments: [
                        sourceIdentity,
                        preview.schemaVersion.map(String.init),
                        receiptSummary,
                    ]
                )
                return result
            }
        } catch let error as HostStateRepositoryError {
            throw error
        } catch {
            throw HostStateRepositoryError.databaseWriteFailed(
                path: databaseURL.path,
                reason: String(describing: error)
            )
        }
    }

    public func hasSupersetImportReceipt(sourceURL: URL) async throws -> Bool {
        let identity = Self.normalizedPath(sourceURL.standardizedFileURL.path)
        do {
            return try await database.read { database in
                try Bool.fetchOne(
                    database,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM import_receipts
                        WHERE source_kind = 'superset' AND source_identity = ?
                    )
                    """,
                    arguments: [identity]
                ) ?? false
            }
        } catch {
            throw HostStateRepositoryError.databaseReadFailed(
                path: databaseURL.path,
                reason: String(describing: error)
            )
        }
    }

    public func loadClientLayout(
        clientID: ClientID,
        defaultWindowID: ClientWindowID
    ) async throws -> ClientLayoutSnapshot {
        do {
            return try await database.read { database in
                let windowRows = try Row.fetchAll(
                    database,
                    sql: """
                    SELECT id, sidebar_width, sidebar_collapsed, window_width,
                           window_height, active_workspace_id
                    FROM client_windows
                    WHERE client_id = ?
                    ORDER BY updated_at, id
                    """,
                    arguments: [clientID.description]
                )
                if windowRows.isEmpty {
                    return ClientLayoutSnapshot(clientID: clientID)
                }
                let windows = try windowRows.map { row -> ClientWindowLayout in
                    let windowID: ClientWindowID = try Self.domainID(
                        row: row, table: "client_windows", column: "id"
                    )
                    let activeWorkspaceID: WorkspaceID? = try Self.optionalDomainID(
                        row: row, table: "client_windows", column: "active_workspace_id"
                    )
                    let width: Double? = row["window_width"]
                    let height: Double? = row["window_height"]
                    let windowSize = width.flatMap { width in
                        height.flatMap { LayoutSize(width: width, height: $0) }
                    }
                    let viewRows = try Row.fetchAll(
                        database,
                        sql: """
                        SELECT workspace_id, active_tab_id
                        FROM workspace_views
                        WHERE window_id = ?
                        ORDER BY position, updated_at, workspace_id
                        """,
                        arguments: [windowID.description]
                    )
                    let views = try viewRows.map { viewRow -> ClientWorkspaceView in
                        let workspaceID: WorkspaceID = try Self.domainID(
                            row: viewRow, table: "workspace_views", column: "workspace_id"
                        )
                        let tabs = try Row.fetchAll(
                            database,
                            sql: """
                            SELECT t.id, t.session_id, s.title, s.kind
                            FROM tabs t
                            JOIN terminal_sessions s ON s.id = t.session_id
                            WHERE t.window_id = ? AND t.workspace_id = ?
                            ORDER BY t.position, t.created_at, t.id
                            """,
                            arguments: [windowID.description, workspaceID.description]
                        ).map { tabRow -> ClientTab in
                            let kindValue: String = tabRow["kind"]
                            guard let kind = TerminalSessionKind(rawValue: kindValue) else {
                                throw HostStateRepositoryError.invalidDatabaseValue(
                                    table: "tabs", column: "kind", value: kindValue
                                )
                            }
                            let sessionID: TerminalSessionID = try Self.domainID(
                                row: tabRow, table: "tabs", column: "session_id"
                            )
                            return ClientTab(
                                id: tabRow["id"],
                                title: (tabRow["title"] as String?) ?? kind.displayName,
                                sessionID: sessionID,
                                kind: kind
                            )
                        }
                        return ClientWorkspaceView(
                            workspaceID: workspaceID,
                            tabs: tabs,
                            activeTabID: viewRow["active_tab_id"]
                        )
                    }
                    guard let window = ClientWindowLayout(
                        id: windowID,
                        sidebarWidth: row["sidebar_width"],
                        sidebarCollapsed: row["sidebar_collapsed"],
                        windowSize: windowSize,
                        activeWorkspaceID: activeWorkspaceID,
                        workspaceViews: views
                    ) else {
                        throw HostStateRepositoryError.invalidDatabaseValue(
                            table: "client_windows", column: "sidebar_width", value: "invalid"
                        )
                    }
                    return window
                }
                return ClientLayoutSnapshot(clientID: clientID, windows: windows)
            }
        } catch let error as HostStateRepositoryError {
            throw error
        } catch {
            throw HostStateRepositoryError.databaseReadFailed(
                path: databaseURL.path,
                reason: String(describing: error)
            )
        }
    }

    public func saveClientLayout(_ layout: ClientLayoutSnapshot) async throws {
        do {
            try await database.write { database in
                let existingWindowIDs = try String.fetchAll(
                    database,
                    sql: "SELECT id FROM client_windows WHERE client_id = ?",
                    arguments: [layout.clientID.description]
                )
                for windowID in existingWindowIDs {
                    try database.execute(
                        sql: "DELETE FROM client_windows WHERE id = ?",
                        arguments: [windowID]
                    )
                }
                for window in layout.windows {
                    try database.execute(
                        sql: """
                        INSERT INTO client_windows (
                            id, client_id, sidebar_width, sidebar_collapsed,
                            window_width, window_height, active_workspace_id
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            window.id.description,
                            layout.clientID.description,
                            window.sidebarWidth,
                            window.sidebarCollapsed,
                            window.windowSize?.width,
                            window.windowSize?.height,
                            window.activeWorkspaceID?.description,
                        ]
                    )
                    for (viewPosition, view) in window.workspaceViews.enumerated() {
                        let validActiveTabID = view.tabs.contains(where: { $0.id == view.activeTabID })
                            ? view.activeTabID
                            : nil
                        try database.execute(
                            sql: """
                            INSERT INTO workspace_views (
                                window_id, workspace_id, active_tab_id, position
                            ) VALUES (?, ?, ?, ?)
                            """,
                            arguments: [
                                window.id.description,
                                view.workspaceID.description,
                                validActiveTabID,
                                viewPosition,
                            ]
                        )
                        for (position, tab) in view.tabs.enumerated() {
                            guard let sessionID = tab.sessionID else { continue }
                            try database.execute(
                                sql: """
                                INSERT INTO tabs (
                                    id, window_id, workspace_id, session_id, position
                                ) VALUES (?, ?, ?, ?, ?)
                                """,
                                arguments: [
                                    tab.id,
                                    window.id.description,
                                    view.workspaceID.description,
                                    sessionID.description,
                                    position,
                                ]
                            )
                        }
                    }
                }
            }
        } catch {
            throw HostStateRepositoryError.databaseWriteFailed(
                path: databaseURL.path,
                reason: String(describing: error)
            )
        }
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_resource_authority") { database in
            try database.create(table: "hosts") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("kind", .text).notNull().defaults(to: "local")
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try database.create(table: "projects") { table in
                table.column("id", .text).primaryKey()
                table.column("host_id", .text).notNull()
                    .references("hosts", onDelete: .cascade)
                table.column("name", .text).notNull()
                table.column("repository_path", .text).notNull()
                table.column("repository_identity", .text).notNull()
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.uniqueKey(["host_id", "repository_identity"])
            }
            try database.create(table: "workspaces") { table in
                table.column("id", .text).primaryKey()
                table.column("project_id", .text).notNull()
                    .references("projects", onDelete: .cascade)
                table.column("name", .text).notNull()
                table.column("path", .text).notNull()
                table.column("normalized_path", .text).notNull().unique()
                table.column("branch", .text)
                table.column("kind", .text).notNull()
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try database.create(table: "terminal_sessions") { table in
                table.column("id", .text).primaryKey()
                table.column("workspace_id", .text).notNull()
                    .references("workspaces", onDelete: .restrict)
                table.column("epoch", .text).notNull()
                table.column("sequence", .text).notNull()
                table.column("working_directory", .text).notNull()
                table.column("columns", .integer).notNull().check { $0 > 0 }
                table.column("rows", .integer).notNull().check { $0 > 0 }
                table.column("kind", .text).notNull()
                table.column("title", .text)
                table.column("is_tab_visible", .boolean).notNull().defaults(to: true)
                table.column("lifecycle", .text).notNull()
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.column("ended_at", .datetime)
            }
            try database.create(table: "runtime_bindings") { table in
                table.column("session_id", .text).primaryKey()
                    .references("terminal_sessions", onDelete: .cascade)
                table.column("adapter", .text).notNull()
                table.column("runtime_identifier", .text).notNull().unique()
                table.column("metadata_json", .text).notNull().defaults(to: "{}")
            }
            try database.create(table: "import_receipts") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("source_kind", .text).notNull()
                table.column("source_identity", .text).notNull()
                table.column("source_version", .text)
                table.column("summary_json", .text).notNull()
                table.column("completed_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.uniqueKey(["source_kind", "source_identity"])
            }
            try database.create(table: "request_receipts") { table in
                table.column("request_id", .text).primaryKey()
                table.column("command_kind", .text).notNull()
                table.column("resource_id", .text).notNull()
                table.column("completed_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
        }
        migrator.registerMigration("v2_client_layout_authority") { database in
            try database.create(table: "client_windows") { table in
                table.column("id", .text).primaryKey()
                table.column("client_id", .text).notNull()
                table.column("sidebar_width", .double).notNull().defaults(to: 240)
                table.column("sidebar_collapsed", .boolean).notNull().defaults(to: false)
                table.column("window_width", .double)
                table.column("window_height", .double)
                table.column("active_workspace_id", .text)
                    .references("workspaces", onDelete: .setNull)
                table.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try database.create(table: "workspace_views") { table in
                table.column("window_id", .text).notNull()
                    .references("client_windows", onDelete: .cascade)
                table.column("workspace_id", .text).notNull()
                    .references("workspaces", onDelete: .cascade)
                table.column("active_tab_id", .text)
                table.column("position", .integer).notNull().defaults(to: 0)
                table.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.primaryKey(["window_id", "workspace_id"])
                table.uniqueKey(["window_id", "position"])
            }
            try database.create(table: "tabs") { table in
                table.column("id", .text).notNull()
                table.column("window_id", .text).notNull()
                    .references("client_windows", onDelete: .cascade)
                table.column("workspace_id", .text).notNull()
                    .references("workspaces", onDelete: .cascade)
                table.column("session_id", .text).notNull()
                    .references("terminal_sessions", onDelete: .cascade)
                table.column("position", .integer).notNull().check { $0 >= 0 }
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.primaryKey(["window_id", "id"])
                table.uniqueKey(["window_id", "workspace_id", "session_id"])
                table.uniqueKey(["window_id", "workspace_id", "position"])
            }
            try database.create(
                index: "tabs_workspace_session_guard",
                on: "tabs",
                columns: ["workspace_id", "session_id"]
            )
            try database.execute(sql: """
                CREATE TRIGGER tabs_workspace_matches_session_insert
                BEFORE INSERT ON tabs
                WHEN NOT EXISTS (
                    SELECT 1 FROM terminal_sessions s
                    WHERE s.id = NEW.session_id
                      AND s.workspace_id = NEW.workspace_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'tab workspace does not match session workspace');
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER tabs_workspace_matches_session_update
                BEFORE UPDATE OF workspace_id, session_id ON tabs
                WHEN NOT EXISTS (
                    SELECT 1 FROM terminal_sessions s
                    WHERE s.id = NEW.session_id
                      AND s.workspace_id = NEW.workspace_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'tab workspace does not match session workspace');
                END
                """)
        }
        return migrator
    }()

    private static func normalizedPath(_ value: String) -> String {
        URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private static func domainID<Tag: Sendable>(
        row: Row,
        table: String,
        column: String
    ) throws -> DomainID<Tag> {
        let value: String = row[column]
        guard let id = DomainID<Tag>(uuidString: value) else {
            throw HostStateRepositoryError.invalidDatabaseValue(
                table: table,
                column: column,
                value: value
            )
        }
        return id
    }

    private static func optionalDomainID<Tag: Sendable>(
        row: Row,
        table: String,
        column: String
    ) throws -> DomainID<Tag>? {
        guard let value: String = row[column] else { return nil }
        guard let id = DomainID<Tag>(uuidString: value) else {
            throw HostStateRepositoryError.invalidDatabaseValue(
                table: table,
                column: column,
                value: value
            )
        }
        return id
    }
}
