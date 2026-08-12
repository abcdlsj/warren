import Foundation
import XCTest
import BurrowApplication
import BurrowDomain
import BurrowStateStore
import BurrowTmuxRuntime

final class ApplicationIntegrationTests: XCTestCase {
    func testLocalTmuxSessionSurvivesAdapterRestartAndReplaysOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-e2e-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        let stateURL = root.appendingPathComponent("state/host-state.json")
        let outputURL = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = JSONFileHostStateRepository(fileURL: stateURL)
        let firstRuntime = TmuxRuntime(outputDirectory: outputURL)
        let firstService = BurrowApplicationService(repository: repository, runtime: firstRuntime)
        try await firstService.start()
        let project = try await firstService.addProject(folder: workspaceURL)
        let projectSnapshot = await firstService.snapshot()
        let workspace = try XCTUnwrap(
            projectSnapshot.workspaces.first { $0.projectID == project.id }
        )
        _ = try await firstService.addTab(workspaceID: workspace.id)
        let sessionSnapshot = await firstService.snapshot()
        let created = try XCTUnwrap(sessionSnapshot.sessions.first)
        let tmuxName = TmuxSessionNaming.name(for: created.id)
        defer { try? Self.killTmuxSession(named: tmuxName) }

        let attachmentID = try XCTUnwrap(created.attachmentID)
        let marker = "DEN_E2E_\(UUID().uuidString)"
        try await firstService.sendInput(
            sessionID: created.id,
            attachmentID: attachmentID,
            data: Data("printf '\(marker)\\n'\n".utf8)
        )
        let resized = try XCTUnwrap(TerminalSize(columns: 101, rows: 37))
        try await firstService.resize(
            sessionID: created.id,
            attachmentID: attachmentID,
            size: resized
        )

        let live = try await snapshot(from: firstService, sessionID: created.id) {
            $0.output?.frames.contains { $0.payload.range(of: Data(marker.utf8)) != nil } == true
        }
        XCTAssertEqual(live.terminalSize, resized)
        let isAliveBeforeRestart = await firstRuntime.exists(sessionID: created.id)
        XCTAssertTrue(isAliveBeforeRestart)

        await firstService.shutdown()
        await firstRuntime.shutdown()
        let isAliveAfterRestart = await firstRuntime.exists(sessionID: created.id)
        XCTAssertTrue(isAliveAfterRestart)

        let secondRuntime = TmuxRuntime(outputDirectory: outputURL)
        let secondService = BurrowApplicationService(repository: repository, runtime: secondRuntime)
        try await secondService.start()
        let restored = try await snapshot(from: secondService, sessionID: created.id) {
            $0.connectionState == .attached &&
                $0.output?.frames.contains { $0.payload.range(of: Data(marker.utf8)) != nil } == true
        }
        XCTAssertEqual(restored.id, created.id)
        XCTAssertEqual(restored.recoveryAnchor?.epoch, 1)
        XCTAssertEqual(restored.terminalSize, resized)

        await secondService.shutdown()
        await secondRuntime.shutdown()
    }

    private func snapshot(
        from service: BurrowApplicationService,
        sessionID: TerminalSessionID,
        matching predicate: @escaping @Sendable (BurrowApplicationSession) -> Bool
    ) async throws -> BurrowApplicationSession {
        let stream = await service.snapshots()
        return try await withThrowingTaskGroup(of: BurrowApplicationSession.self) { group in
            group.addTask {
                for await value in stream {
                    if let session = value.session(id: sessionID), predicate(session) {
                        return session
                    }
                }
                throw IntegrationError.timeout
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw IntegrationError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func killTmuxSession(named name: String) throws {
        guard name.hasPrefix(TmuxSessionNaming.prefix) else {
            throw IntegrationError.invalidCleanupTarget
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "kill-session", "-t", name]
        try process.run()
        process.waitUntilExit()
    }
}

private enum IntegrationError: Error {
    case timeout
    case invalidCleanupTarget
}
