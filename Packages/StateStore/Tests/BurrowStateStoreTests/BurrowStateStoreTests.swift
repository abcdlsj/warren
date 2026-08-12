import Foundation
import XCTest
@testable import BurrowStateStore
import BurrowDomain

final class BurrowStateStoreTests: XCTestCase {
    func testJSONRoundTripPreservesRecoverableState() async throws {
        let host = Host(name: "Mac")
        let project = Project(hostID: host.id, name: "Burrow", rootPath: "/tmp/burrow")
        let workspace = Workspace(
            projectID: project.id,
            name: "main",
            path: "/tmp/burrow",
            branch: "main"
        )
        let persistedSession = PersistedTerminalSession(
            workspaceID: workspace.id,
            epoch: 4,
            sequence: 19,
            workingDirectory: "/tmp/burrow",
            terminalSize: try XCTUnwrap(TerminalSize(columns: 120, rows: 40)),
            runtimeAdoptionDescriptor: RuntimeAdoptionDescriptor(
                runtime: "tmux",
                identifier: "burrow-main",
                metadata: ["window": "0"]
            )
        )
        let state = PersistedHostState(
            hosts: [host],
            projects: [project],
            workspaces: [workspace],
            terminalSessions: [persistedSession]
        )
        let temporaryFile = try TemporaryStateFile()
        defer { try? temporaryFile.cleanup() }
        let repository = JSONFileHostStateRepository(fileURL: temporaryFile.url)

        try await repository.save(state)
        let loaded = try await repository.load()

        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.terminalSessions[0].terminalSession.epoch, 4)
        XCTAssertEqual(loaded.terminalSessions[0].terminalSize.columns, 120)
    }

    func testSaveAtomicallyOverwritesPreviousDocument() async throws {
        let temporaryFile = try TemporaryStateFile()
        defer { try? temporaryFile.cleanup() }
        let repository = JSONFileHostStateRepository(fileURL: temporaryFile.url)
        let first = PersistedHostState(hosts: [Host(name: "first")])
        let second = PersistedHostState(hosts: [Host(name: "second")])

        try await repository.save(first)
        let firstData = try Data(contentsOf: temporaryFile.url)
        try await repository.save(second)
        let secondData = try Data(contentsOf: temporaryFile.url)
        let loaded = try await repository.load()

        XCTAssertNotEqual(firstData, secondData)
        XCTAssertEqual(loaded, second)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: temporaryFile.url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".\(temporaryFile.url.lastPathComponent).") &&
            $0.pathExtension == "tmp" }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testMissingFileReturnsEmptyState() async throws {
        let temporaryFile = try TemporaryStateFile()
        defer { try? temporaryFile.cleanup() }
        let repository = JSONFileHostStateRepository(fileURL: temporaryFile.url)
        let state = try await repository.load()

        XCTAssertEqual(state, .empty)
    }

    func testCorruptedJSONReturnsStructuredError() async throws {
        let temporaryFile = try TemporaryStateFile()
        defer { try? temporaryFile.cleanup() }
        try Data("{ definitely not JSON".utf8).write(to: temporaryFile.url)
        let repository = JSONFileHostStateRepository(fileURL: temporaryFile.url)

        do {
            _ = try await repository.load()
            XCTFail("Expected corrupted JSON to fail")
        } catch let error as HostStateRepositoryError {
            guard case .corruptedJSON = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFutureSchemaReturnsStructuredError() async throws {
        let temporaryFile = try TemporaryStateFile()
        defer { try? temporaryFile.cleanup() }
        let futureState = PersistedHostState(schemaVersion: 3)
        try JSONEncoder().encode(futureState).write(to: temporaryFile.url)
        let repository = JSONFileHostStateRepository(fileURL: temporaryFile.url)

        do {
            _ = try await repository.load()
            XCTFail("Expected a future schema to fail")
        } catch let error as HostStateRepositoryError {
            XCTAssertEqual(
                error,
                .unsupportedSchemaVersion(found: 3, supported: PersistedHostState.currentSchemaVersion)
            )
        }
    }

    func testTransientStateCannotEnterPersistedModel() throws {
        let state = PersistedHostState(hosts: [Host(name: "Mac")])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        XCTAssertNil(object["attachments"])
        XCTAssertNil(object["controlLeases"])
        XCTAssertNil(object["clientLayouts"])
        XCTAssertFalse(Mirror(reflecting: state).children.contains { child in
            ["attachments", "controlLease", "clientLayout"].contains(child.label ?? "")
        })
    }

    func testLegacySessionJSONDefaultsKindToShellAndKeepsRecoveryFields() throws {
        let json = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "workspaceID": "22222222-2222-4222-8222-222222222222",
          "epoch": 3,
          "sequence": 12,
          "workingDirectory": "/tmp/burrow",
          "terminalSize": {"columns": 120, "rows": 40}
        }
        """
        let session = try JSONDecoder().decode(
            PersistedTerminalSession.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(session.kind, .shell)
        XCTAssertNil(session.title)
        XCTAssertEqual(session.epoch, 3)
        XCTAssertEqual(session.sequence, 12)
        XCTAssertEqual(session.terminalSize.columns, 120)
    }
}

private struct TemporaryStateFile {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BurrowStateStoreTests-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("host-state.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() throws {
        try FileManager.default.removeItem(at: directory)
    }
}
