import Foundation
import GRDB

/// Small GRDB wrapper that owns schema migration and exposes reader/writer handles.
public struct AppDatabase: Sendable {
    private let dbWriter: any DatabaseWriter

    public var reader: any DatabaseReader { dbWriter }
    public var writer: any DatabaseWriter { dbWriter }

    public init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    public static func inMemory() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue(configuration: Self.makeConfiguration())
        return try AppDatabase(dbQueue)
    }

    public static func onDisk(path: String) throws -> AppDatabase {
        let dbPool = try DatabasePool(
            path: path,
            configuration: Self.makeConfiguration()
        )
        return try AppDatabase(dbPool)
    }

    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return config
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_createProjects") { db in
            // Project rows are the durable root entity. Worktrees cascade from here.
            try db.create(table: "project") { t in
                t.primaryKey("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("shortName", .text).notNull().defaults(to: "")
                t.column("repoRootPath", .text).notNull()
                t.column("gitCommonDir", .text).notNull().defaults(to: "")
                t.column("originURL", .text)
                t.column("iconName", .text)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("isCollapsed", .boolean).notNull().defaults(to: false)
                t.column("lastActiveAt", .datetime)
            }
        }

        migrator.registerMigration("v1_createWorktrees") { db in
            // Worktree rows mix durable metadata with denormalized git/tmux status for fast sidebar rendering.
            try db.create(table: "worktree") { t in
                t.primaryKey("id", .text).notNull()
                t.column("projectId", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("path", .text).notNull()
                t.column("branch", .text)
                t.column("headSHA", .text)
                t.column("isMainWorktree", .boolean).notNull().defaults(to: false)
                t.column("isDetached", .boolean).notNull().defaults(to: false)
                t.column("hasUncommittedChanges", .boolean).notNull().defaults(to: false)
                t.column("aheadCount", .integer).notNull().defaults(to: 0)
                t.column("behindCount", .integer).notNull().defaults(to: 0)
                t.column("lastActiveAt", .datetime)
                t.column("tmuxSessionId", .text)
                t.column("tmuxSessionName", .text)
            }
        }

        migrator.registerMigration("v1_createUIState") { db in
            // UI state is stored as a singleton row keyed by `id = 1`.
            try db.create(table: "uiState") { t in
                t.primaryKey("id", .integer)
                t.column("selectedProjectId", .text)
                t.column("selectedWorktreeId", .text)
                t.column("selectedWindowId", .text)
                t.column("sidebarMode", .text).notNull().defaults(to: "worktrees")
                t.column("searchQuery", .text).notNull().defaults(to: "")
            }
        }

        return migrator
    }
}
