import Foundation
import WarrenDomain
import GRDB
import XCTest
@testable import WarrenStateStore

final class SupersetImportSourceTests: XCTestCase {
    func testCommitUsesNewIDsCreatesNoSessionsAndWritesIdempotentReceipt() async throws {
        let sourceFixture = try SupersetFixtureDatabase()
        defer { try? sourceFixture.cleanup() }
        let destination = try TemporaryImportDatabase()
        defer { try? destination.cleanup() }
        let host = WarrenDomain.Host(name: "Mac")
        let repository = try SQLiteHostStateRepository(databaseURL: destination.url)
        try await repository.save(PersistedHostState(hosts: [host]))
        let source = try SupersetImportSource(
            databaseURL: sourceFixture.url,
            pathInspector: FixturePathInspector(
                directories: [
                    "/repos/alpha": "/real/alpha",
                    "/repos/alpha-wt": "/real/alpha-wt",
                ],
                gitPaths: ["/real/alpha", "/real/alpha-wt"]
            )
        )
        let preview = try await source.preview()

        let first = try await repository.importSuperset(preview, into: host.id)
        let state = try await repository.load()
        let second = try await repository.importSuperset(preview, into: host.id)

        XCTAssertEqual(first.importedProjectIDs.count, 1)
        XCTAssertEqual(first.importedWorkspaceIDs.count, 2)
        XCTAssertFalse(first.wasAlreadyImported)
        XCTAssertEqual(state.projects.count, 1)
        XCTAssertEqual(state.workspaces.count, 2)
        XCTAssertTrue(state.terminalSessions.isEmpty)
        XCTAssertNotEqual(state.projects[0].id.description, "project-1")
        let hasReceipt = try await repository.hasSupersetImportReceipt(sourceURL: sourceFixture.url)
        XCTAssertTrue(hasReceipt)
        XCTAssertTrue(second.wasAlreadyImported)
        XCTAssertTrue(second.importedProjectIDs.isEmpty)
        XCTAssertTrue(second.importedWorkspaceIDs.isEmpty)
        let afterSecond = try await repository.load()
        XCTAssertEqual(afterSecond, state)
    }

    func testCommitRollsBackWhenHostDoesNotExist() async throws {
        let sourceFixture = try SupersetFixtureDatabase()
        defer { try? sourceFixture.cleanup() }
        let destination = try TemporaryImportDatabase()
        defer { try? destination.cleanup() }
        let repository = try SQLiteHostStateRepository(databaseURL: destination.url)
        let source = try SupersetImportSource(
            databaseURL: sourceFixture.url,
            pathInspector: FixturePathInspector(
                directories: [
                    "/repos/alpha": "/real/alpha",
                    "/repos/alpha-wt": "/real/alpha-wt",
                ],
                gitPaths: ["/real/alpha", "/real/alpha-wt"]
            )
        )
        let preview = try await source.preview()

        do {
            _ = try await repository.importSuperset(preview, into: HostID())
            XCTFail("Expected missing Host to reject import")
        } catch let error as HostStateRepositoryError {
            guard case .invalidDatabaseValue = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let state = try await repository.load()
        let hasReceipt = try await repository.hasSupersetImportReceipt(sourceURL: sourceFixture.url)
        XCTAssertEqual(state, .empty)
        XCTAssertFalse(hasReceipt)
    }

    func testPreviewReadsProjectsAndDeduplicatesWorkspacePaths() async throws {
        let fixture = try SupersetFixtureDatabase()
        defer { try? fixture.cleanup() }
        let inspector = FixturePathInspector(
            directories: [
                "/repos/alpha": "/real/alpha",
                "/repos/alpha-wt": "/real/alpha-wt",
            ],
            gitPaths: ["/real/alpha", "/real/alpha-wt"]
        )
        let source = try SupersetImportSource(
            databaseURL: fixture.url,
            pathInspector: inspector
        )

        let preview = try await source.preview()

        XCTAssertEqual(preview.projects.count, 1)
        let project = try XCTUnwrap(preview.projects.first)
        XCTAssertEqual(project.sourceProjectID, "project-1")
        XCTAssertEqual(project.repositoryPath, "/real/alpha")
        XCTAssertEqual(project.status, .ready)
        XCTAssertEqual(project.workspaces.count, 2)
        XCTAssertEqual(project.workspaces.map(\.path), ["/real/alpha", "/real/alpha-wt"])
        XCTAssertEqual(project.workspaces.map(\.status), [.ready, .ready])
        XCTAssertEqual(project.workspaces[1].branch, "feature/import")
    }

    func testPreviewClassifiesMissingAndInvalidPaths() async throws {
        let fixture = try SupersetFixtureDatabase()
        defer { try? fixture.cleanup() }
        let source = try SupersetImportSource(
            databaseURL: fixture.url,
            pathInspector: FixturePathInspector(
                directories: ["/repos/alpha": "/real/alpha"],
                gitPaths: []
            )
        )

        let preview = try await source.preview()
        let project = try XCTUnwrap(preview.projects.first)

        XCTAssertEqual(project.status, .invalid)
        XCTAssertEqual(project.workspaces.map(\.status), [.invalid, .missing])
    }

    func testPreviewRejectsIncompatibleSchema() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WarrenSupersetSchemaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local.db")
        let database = try DatabaseQueue(path: url.path)
        try await database.write { database in
            try database.execute(sql: "CREATE TABLE projects (id TEXT PRIMARY KEY)")
        }
        let source = try SupersetImportSource(
            databaseURL: url,
            pathInspector: FixturePathInspector(directories: [:], gitPaths: [])
        )

        do {
            _ = try await source.preview()
            XCTFail("Expected incompatible schema")
        } catch let error as SupersetImportSourceError {
            guard case .incompatibleSchema(let missing) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(missing.contains("workspaces"))
            XCTAssertTrue(missing.contains("worktrees"))
            XCTAssertTrue(missing.contains("projects.main_repo_path"))
        }
    }

    func testPreviewDoesNotModifySourceDatabase() async throws {
        let fixture = try SupersetFixtureDatabase()
        defer { try? fixture.cleanup() }
        let beforeData = try Data(contentsOf: fixture.url)
        let beforeAttributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
        let source = try SupersetImportSource(
            databaseURL: fixture.url,
            pathInspector: FixturePathInspector(
                directories: [
                    "/repos/alpha": "/real/alpha",
                    "/repos/alpha-wt": "/real/alpha-wt",
                ],
                gitPaths: ["/real/alpha", "/real/alpha-wt"]
            )
        )

        _ = try await source.preview()

        let afterData = try Data(contentsOf: fixture.url)
        let afterAttributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
        XCTAssertEqual(afterData, beforeData)
        XCTAssertEqual(
            afterAttributes[.modificationDate] as? Date,
            beforeAttributes[.modificationDate] as? Date
        )
    }

    func testSelectingProjectsFiltersPreviewCandidates() async throws {
        let fixture = try SupersetFixtureDatabase()
        defer { try? fixture.cleanup() }
        let source = try SupersetImportSource(
            databaseURL: fixture.url,
            pathInspector: FixturePathInspector(
                directories: [
                    "/repos/alpha": "/real/alpha",
                    "/repos/alpha-wt": "/real/alpha-wt",
                ],
                gitPaths: ["/real/alpha", "/real/alpha-wt"]
            )
        )
        let preview = try await source.preview()

        let projectID = try XCTUnwrap(preview.projects.first?.id)
        let selection = preview.selectingProjects([projectID])
        XCTAssertEqual(selection.sourcePath, preview.sourcePath)
        XCTAssertEqual(selection.schemaVersion, preview.schemaVersion)
        XCTAssertEqual(selection.projects.map(\.id), [projectID])
        XCTAssertEqual(selection.projects.first?.workspaces, preview.projects.first?.workspaces)
        XCTAssertEqual(preview.selectingProjects([]).projects.count, 0)
        XCTAssertEqual(preview.readyProjectIDs, [projectID])
    }
}

private struct TemporaryImportDatabase {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WarrenImportCommit-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("state.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() throws {
        try FileManager.default.removeItem(at: directory)
    }
}

private struct FixturePathInspector: SupersetImportPathInspecting {
    let directories: [String: String]
    let gitPaths: Set<String>

    func normalizedExistingDirectory(at path: String) -> String? {
        directories[path]
    }

    func isGitWorktree(at path: String) -> Bool {
        gitPaths.contains(path)
    }
}

private struct SupersetFixtureDatabase {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WarrenSupersetFixture-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("local.db")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabaseQueue(path: url.path)
        try database.write { database in
            try database.execute(sql: """
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY,
                    main_repo_path TEXT NOT NULL,
                    name TEXT NOT NULL,
                    tab_order INTEGER,
                    last_opened_at INTEGER NOT NULL
                );
                CREATE TABLE worktrees (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    path TEXT NOT NULL,
                    branch TEXT NOT NULL
                );
                CREATE TABLE workspaces (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    worktree_id TEXT,
                    type TEXT NOT NULL,
                    branch TEXT NOT NULL,
                    name TEXT NOT NULL,
                    tab_order INTEGER NOT NULL,
                    deleting_at INTEGER
                );
                INSERT INTO projects VALUES (
                    'project-1', '/repos/alpha', 'Alpha', 0, 100
                );
                INSERT INTO worktrees VALUES (
                    'worktree-1', 'project-1', '/repos/alpha-wt', 'feature/import'
                );
                INSERT INTO workspaces VALUES (
                    'workspace-main', 'project-1', NULL, 'branch', 'main', 'main', 0, NULL
                );
                INSERT INTO workspaces VALUES (
                    'workspace-main-duplicate', 'project-1', NULL, 'branch', 'main', 'duplicate', 1, NULL
                );
                INSERT INTO workspaces VALUES (
                    'workspace-wt', 'project-1', 'worktree-1', 'worktree',
                    'feature/import', 'feature/import', 2, NULL
                );
            """)
        }
    }

    func cleanup() throws {
        try FileManager.default.removeItem(at: directory)
    }
}
