import Foundation
import XCTest
import BurrowStateStore
@testable import BurrowNext

final class BurrowProcessTests: XCTestCase {
    func testSingleInstanceLockRejectsConcurrentOwnersAndCanBeReacquired() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-instance-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("application.lock")

        var owner: BurrowSingleInstanceLock? = try XCTUnwrap(
            BurrowSingleInstanceLock(fileURL: lockURL)
        )
        XCTAssertNotNil(owner)
        for _ in 0..<5 {
            XCTAssertNil(BurrowSingleInstanceLock(fileURL: lockURL))
        }
        owner = nil
        XCTAssertNotNil(BurrowSingleInstanceLock(fileURL: lockURL))
    }

    func testHeadlessProductStartsEmptyAndExitsWithoutCreatingSessions() async throws {
        guard let executable = ProcessInfo.processInfo.environment["BURROW_APP_EXECUTABLE"] else {
            throw XCTSkip("BURROW_APP_EXECUTABLE is provided by scripts/verify.sh")
        }
        let fixture = try ProcessFixture()
        defer { fixture.cleanup() }

        let result = try await fixture.run(executable: executable)

        XCTAssertEqual(result.status, 0, result.stderr)
        let repository = try SQLiteHostStateRepository(databaseURL: fixture.databaseURL)
        let state = try await repository.load()
        XCTAssertTrue(state.terminalSessions.isEmpty)
    }

    func testHeadlessProductRejectsSecondInstanceAndQuitKeepsTmuxAlive() async throws {
        guard let executable = ProcessInfo.processInfo.environment["BURROW_APP_EXECUTABLE"] else {
            throw XCTSkip("BURROW_APP_EXECUTABLE is provided by scripts/verify.sh")
        }
        let fixture = try ProcessFixture()
        defer { fixture.cleanup() }
        let first = try fixture.launch(
            executable: executable,
            extraEnvironment: [
                "BURROW_HEADLESS_HOLD_MILLISECONDS": "500",
                "BURROW_HEADLESS_CREATE_SESSION_PATH": fixture.workspaceURL.path,
            ]
        )
        try await fixture.waitForLockOwner(timeout: .seconds(2))

        let second = try await fixture.run(executable: executable)
        XCTAssertEqual(second.status, 73, second.stderr)
        first.waitUntilExit()
        XCTAssertEqual(first.terminationStatus, 0)

        let report = try JSONDecoder().decode(
            HeadlessReport.self,
            from: Data(contentsOf: fixture.reportURL)
        )
        XCTAssertNil(report.error)
        XCTAssertTrue(report.runtimeAliveAfterShutdown)
        let sessionID = try XCTUnwrap(report.sessionID)
        defer { fixture.killTmuxSession(sessionID: sessionID) }
        XCTAssertTrue(fixture.tmuxSessionExists(sessionID: sessionID))
    }
}

private struct HeadlessReport: Decodable {
    let sessionID: String?
    let runtimeAliveAfterShutdown: Bool
    let error: String?
}

private final class ProcessFixture: @unchecked Sendable {
    struct Result {
        let status: Int32
        let stderr: String
    }

    let root: URL
    let databaseURL: URL
    let runtimeURL: URL
    let lockURL: URL
    let reportURL: URL
    let workspaceURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-process-\(UUID().uuidString)", isDirectory: true)
        databaseURL = root.appendingPathComponent("state.sqlite3")
        runtimeURL = root.appendingPathComponent("runtime", isDirectory: true)
        lockURL = root.appendingPathComponent("application.lock")
        reportURL = root.appendingPathComponent("report.json")
        workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    }

    func launch(
        executable: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.environment = ProcessInfo.processInfo.environment.merging([
            "BURROW_HEADLESS_ACCEPTANCE": "1",
            "BURROW_STATE_DATABASE": databaseURL.path,
            "BURROW_RUNTIME_OUTPUT_DIRECTORY": runtimeURL.path,
            "BURROW_INSTANCE_LOCK": lockURL.path,
            "BURROW_HEADLESS_REPORT": reportURL.path,
        ].merging(extraEnvironment) { _, new in new }) { _, new in new }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    func run(executable: String) async throws -> Result {
        let process = try launch(executable: executable)
        process.waitUntilExit()
        let stderr = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
            ?? Data()
        return Result(
            status: process.terminationStatus,
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }

    func tmuxSessionExists(sessionID: String) -> Bool {
        runTmux(["has-session", "-t", "burrow-\(sessionID)"]) == 0
    }

    func killTmuxSession(sessionID: String) {
        guard UUID(uuidString: sessionID) != nil else { return }
        _ = runTmux(["kill-session", "-t", "burrow-\(sessionID)"])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func waitForLockOwner(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let content = try? String(contentsOf: lockURL, encoding: .utf8),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(
            domain: "BurrowProcessTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the first instance lock."]
        )
    }

    private func runTmux(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
