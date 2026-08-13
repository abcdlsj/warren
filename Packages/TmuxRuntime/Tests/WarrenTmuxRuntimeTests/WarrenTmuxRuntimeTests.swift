import Foundation
import XCTest
import WarrenDomain
import WarrenHost
@testable import WarrenTmuxRuntime

final class WarrenTmuxRuntimeTests: XCTestCase {
    private let sessionID = TerminalSessionID(
        rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    )

    func testSessionNamingIsStableAndRoundTrips() {
        let name = TmuxSessionNaming.name(for: sessionID)
        XCTAssertEqual(name, "warren-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        XCTAssertTrue(TmuxSessionNaming.isWarrenName(name))
        XCTAssertEqual(TmuxSessionNaming.sessionID(from: name), sessionID)
        XCTAssertFalse(TmuxSessionNaming.isWarrenName("warren-main"))
    }

    func testHostedTerminalEnvironmentDropsLauncherPolicyAndIdentity() {
        let environment = WarrenTerminalEnvironment.sanitized(from: [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/example",
            "TERM": "xterm-ghostty",
            "TERM_PROGRAM": "ghostty",
            "TERM_PROGRAM_VERSION": "1.2.3",
            "NO_COLOR": "1",
            "FORCE_COLOR": "0",
            "CLICOLOR": "0",
            "CLICOLOR_FORCE": "0",
            "TMUX": "/tmp/tmux,1,0",
            "TMUX_PANE": "%1",
            "VSCODE_INJECTION": "1",
            "CLAUDE_CODE_SSE_PORT": "1234",
            "GHOSTTY_RESOURCES_DIR": "/tmp/ghostty",
            "WARREN_CONTROL_PLANE_URL": "https://relay.example.com",
            "WARREN_CONTROL_PLANE_HOST_ID": "00000000-0000-4000-8000-000000000001",
            "WARREN_CONTROL_PLANE_HOST_TOKEN": "secret",
        ])

        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["TERM"], "xterm-ghostty")
        XCTAssertEqual(environment["COLORTERM"], "truecolor")
        XCTAssertEqual(environment["TERM_PROGRAM"], "Warren")
        XCTAssertFalse(environment["TERM_PROGRAM_VERSION", default: ""].isEmpty)
        for key in [
            "NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE",
            "TMUX", "TMUX_PANE", "VSCODE_INJECTION", "CLAUDE_CODE_SSE_PORT",
            "GHOSTTY_RESOURCES_DIR",
            "WARREN_CONTROL_PLANE_URL", "WARREN_CONTROL_PLANE_HOST_ID",
            "WARREN_CONTROL_PLANE_HOST_TOKEN",
        ] {
            XCTAssertNil(environment[key], "Expected \(key) to be removed")
        }
    }

    func testProcessExecutorKeepsConfiguredTmuxSocketsIsolated() async throws {
        let firstSocket = "warren-test-\(UUID().uuidString.lowercased())"
        let secondSocket = "warren-test-\(UUID().uuidString.lowercased())"
        let sessionName = "socket-isolation"
        let first = ProcessTmuxCommandExecutor(socketName: firstSocket)
        let second = ProcessTmuxCommandExecutor(socketName: secondSocket)
        do {
            _ = try await first.execute(arguments: ["-V"])
        } catch let error as TmuxCommandExecutorError {
            throw XCTSkip("tmux is unavailable: \(error.localizedDescription)")
        }
        defer {
            Task {
                _ = try? await first.execute(arguments: ["kill-server"])
                _ = try? await second.execute(arguments: ["kill-server"])
            }
        }

        let created = try await first.execute(arguments: [
            "new-session", "-d", "-s", sessionName,
        ])
        XCTAssertEqual(created.exitCode, 0, created.stderrText)
        let visibleInFirst = try await first.execute(arguments: [
            "has-session", "-t", sessionName,
        ])
        let visibleInSecond = try await second.execute(arguments: [
            "has-session", "-t", sessionName,
        ])

        XCTAssertEqual(visibleInFirst.exitCode, 0)
        XCTAssertNotEqual(visibleInSecond.exitCode, 0)
    }

    func testCreateDeclaresHostedTerminalIdentityWithoutOverridingTerm() async throws {
        let executor = RecordingTmuxExecutor()
        let outputDirectory = try temporaryDirectory()
        let runtime = TmuxRuntime(
            executor: executor,
            outputDirectory: outputDirectory,
            exitPollIntervalNanoseconds: 10_000_000
        )

        _ = try await runtime.create(
            sessionID: sessionID,
            workingDirectory: outputDirectory.path,
            size: TerminalSize(columns: 80, rows: 24)!
        )

        let calls = await executor.calls
        let arguments = try XCTUnwrap(calls.first { $0.arguments.first == "new-session" }?.arguments)
        XCTAssertTrue(arguments.contains("COLORTERM=truecolor"))
        XCTAssertTrue(arguments.contains("TERM_PROGRAM=Warren"))
        XCTAssertTrue(arguments.contains { $0.hasPrefix("TERM_PROGRAM_VERSION=") })
        let shellCommand = try XCTUnwrap(arguments.last)
        for key in ["NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE"] {
            XCTAssertTrue(shellCommand.contains("'-u' '\(key)'"), "Expected shell launch to remove \(key)")
        }
        XCTAssertTrue(shellCommand.contains("'COLORTERM=truecolor'"))
        XCTAssertTrue(shellCommand.contains("'TERM_PROGRAM=Warren'"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("TERM=") })
        await runtime.shutdown()
    }

    func testCreateInjectsWarrenHookEnvironmentPerSession() async throws {
        let executor = RecordingTmuxExecutor()
        let outputDirectory = try temporaryDirectory()
        let runtime = TmuxRuntime(
            executor: executor,
            outputDirectory: outputDirectory,
            sessionEnvironment: [
                "WARREN_HOOK_URL": "http://127.0.0.1:8788/hook",
                "WARREN_HOOK_TOKEN": "test-token",
            ]
        )
        let sessionID = TerminalSessionID()
        _ = try await runtime.create(
            sessionID: sessionID,
            workingDirectory: outputDirectory.path,
            size: TerminalSize(columns: 80, rows: 24)!,
            launchSpec: TerminalRuntimeLaunchSpec.command("claude")
        )
        let commands = await executor.calls
        let newSession = try XCTUnwrap(commands.first { $0.arguments.contains("new-session") })
        let rendered = newSession.arguments.joined(separator: " ")
        XCTAssertTrue(rendered.contains("WARREN_SESSION_ID=\(sessionID.description)"))
        XCTAssertTrue(rendered.contains("WARREN_HOOK_URL=http://127.0.0.1:8788/hook"))
        XCTAssertTrue(rendered.contains("WARREN_HOOK_TOKEN=test-token"))
        await runtime.shutdown()
    }

    func testPresetLaunchStartsAsFirstPaneProcessWithoutSyntheticInput() async throws {
        let executor = RecordingTmuxExecutor()
        let outputDirectory = try temporaryDirectory()
        let runtime = TmuxRuntime(
            executor: executor,
            outputDirectory: outputDirectory,
            exitPollIntervalNanoseconds: 10_000_000
        )

        let descriptor = try await runtime.create(
            sessionID: sessionID,
            workingDirectory: outputDirectory.path,
            size: TerminalSize(columns: 80, rows: 24)!,
            launchSpec: .command("codex --dangerously-bypass-approvals-and-sandbox")
        )

        let calls = await executor.calls
        let creation = try XCTUnwrap(calls.first { $0.arguments.first == "new-session" })
        let shellCommand = try XCTUnwrap(creation.arguments.last)
        XCTAssertTrue(shellCommand.contains("exec codex --dangerously-bypass-approvals-and-sandbox"))
        XCTAssertFalse(calls.contains { $0.arguments.first == "load-buffer" })
        XCTAssertEqual(
            descriptor.metadata["launchSpec"],
            "codex --dangerously-bypass-approvals-and-sandbox"
        )
        await runtime.shutdown()
    }

    func testSpecialKeyInspectAndTerminateUseTypedTmuxOperations() async throws {
        let executor = RecordingTmuxExecutor()
        let outputDirectory = try temporaryDirectory()
        let runtime = TmuxRuntime(
            executor: executor,
            outputDirectory: outputDirectory,
            exitPollIntervalNanoseconds: 10_000_000
        )
        _ = try await runtime.create(
            sessionID: sessionID,
            workingDirectory: outputDirectory.path,
            size: TerminalSize(columns: 80, rows: 24)!
        )

        try await runtime.sendSpecialKey(sessionID: sessionID, key: .interrupt)
        let inspection = try await runtime.inspect(sessionID: sessionID)
        try await runtime.terminate(sessionID: sessionID)

        let calls = await executor.calls
        XCTAssertTrue(calls.contains {
            $0.arguments.first == "send-keys" && $0.arguments.last == "C-c"
        })
        XCTAssertTrue(inspection.isRunning)
        XCTAssertTrue(calls.contains {
            $0.arguments.first == "kill-session" && $0.arguments.contains(TmuxSessionNaming.name(for: sessionID))
        })
        let stillExists = await runtime.exists(sessionID: sessionID)
        XCTAssertFalse(stillExists)
    }

    func testLifecycleObservationUsesOneBatchCommandForMultipleSessions() async throws {
        let executor = RecordingTmuxExecutor()
        let outputDirectory = try temporaryDirectory()
        let runtime = TmuxRuntime(
            executor: executor,
            outputDirectory: outputDirectory,
            exitPollIntervalNanoseconds: 60_000_000_000
        )
        let secondSessionID = TerminalSessionID(
            rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        _ = try await runtime.create(
            sessionID: sessionID,
            workingDirectory: outputDirectory.path,
            size: TerminalSize(columns: 80, rows: 24)!
        )
        _ = try await runtime.create(
            sessionID: secondSessionID,
            workingDirectory: outputDirectory.path,
            size: TerminalSize(columns: 80, rows: 24)!
        )
        let callsBeforeObservation = await executor.calls.count

        let shouldContinue = await runtime.observeManagedSessions()

        let observationCalls = await executor.calls.dropFirst(callsBeforeObservation)
        XCTAssertTrue(shouldContinue)
        XCTAssertEqual(observationCalls.map(\.arguments), [
            ["list-sessions", "-F", "#{session_name}"],
        ])
        await runtime.shutdown()
    }

    func testCreateAndWriteUsesBinarySafeTmuxBuffer() async throws {
        let executor = RecordingTmuxExecutor()
        let outputDirectory = try temporaryDirectory()
        let runtime = TmuxRuntime(
            executor: executor,
            outputDirectory: outputDirectory,
            exitPollIntervalNanoseconds: 10_000_000
        )
        let stream = await runtime.events(for: sessionID)
        let descriptor = try await runtime.create(
            sessionID: sessionID,
            workingDirectory: outputDirectory.path,
            size: TerminalSize(columns: 80, rows: 24)!
        )

        let payload = Data([0x00, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x0A, 0xFF])
        try await runtime.write(sessionID: sessionID, data: payload)

        let calls = await executor.calls
        let loadCall = try XCTUnwrap(calls.first { $0.arguments.first == "load-buffer" })
        XCTAssertEqual(loadCall.standardInput, payload)
        XCTAssertEqual(calls.last?.arguments.first, "paste-buffer")
        let loadBuffer = try XCTUnwrap(argument(after: "-b", in: loadCall.arguments))
        let pasteCall = try XCTUnwrap(calls.last)
        XCTAssertEqual(argument(after: "-b", in: pasteCall.arguments), loadBuffer)
        XCTAssertTrue(loadBuffer.hasPrefix("warren-input-\(sessionID.description)-"))
        XCTAssertEqual(descriptor.runtime, TmuxRuntime.runtimeName)
        XCTAssertEqual(descriptor.identifier, TmuxSessionNaming.name(for: sessionID))

        await runtime.shutdown()
        var iterator = stream.makeAsyncIterator()
        let noUnexpectedEvent = await iterator.next()
        XCTAssertNil(noUnexpectedEvent)
    }

    func testConcurrentWritesStayOrderedAndUseIndependentBuffers() async throws {
        let executor = YieldingTmuxExecutor(blockFirstLoad: true)
        let outputDirectory = try temporaryDirectory()
        let runtime = TmuxRuntime(
            executor: executor,
            outputDirectory: outputDirectory,
            exitPollIntervalNanoseconds: 10_000_000
        )
        _ = try await runtime.create(
            sessionID: sessionID,
            workingDirectory: outputDirectory.path,
            size: TerminalSize(columns: 80, rows: 24)!
        )

        let sessionID = self.sessionID
        let first = Task {
            try await runtime.write(
                sessionID: sessionID,
                data: Data("first".utf8)
            )
        }
        try await executor.waitUntilFirstLoadStarts()
        let second = Task {
            try await runtime.write(
                sessionID: sessionID,
                data: Data("second".utf8)
            )
        }
        await executor.releaseFirstLoad()
        try await first.value
        try await second.value

        let inputCalls = await executor.calls.filter {
            $0.arguments.first == "load-buffer" || $0.arguments.first == "paste-buffer"
        }
        XCTAssertEqual(inputCalls.map { $0.arguments.first! }, [
            "load-buffer", "paste-buffer", "load-buffer", "paste-buffer",
        ])
        let firstBuffer = try XCTUnwrap(argument(after: "-b", in: inputCalls[0].arguments))
        let firstPasteBuffer = try XCTUnwrap(argument(after: "-b", in: inputCalls[1].arguments))
        let secondBuffer = try XCTUnwrap(argument(after: "-b", in: inputCalls[2].arguments))
        let secondPasteBuffer = try XCTUnwrap(argument(after: "-b", in: inputCalls[3].arguments))
        XCTAssertEqual(firstPasteBuffer, firstBuffer)
        XCTAssertEqual(secondPasteBuffer, secondBuffer)
        XCTAssertNotEqual(firstBuffer, secondBuffer)
        XCTAssertEqual(inputCalls[0].standardInput, Data("first".utf8))
        XCTAssertEqual(inputCalls[2].standardInput, Data("second".utf8))
        await runtime.shutdown()
    }

    func testAdoptionReadsOnlyBytesAfterPersistedOffset() async throws {
        let executor = RecordingTmuxExecutor()
        let outputDirectory = try temporaryDirectory()
        let firstRuntime = TmuxRuntime(
            executor: executor,
            outputDirectory: outputDirectory,
            exitPollIntervalNanoseconds: 10_000_000
        )
        let descriptor = try await firstRuntime.create(
            sessionID: sessionID,
            workingDirectory: outputDirectory.path,
            size: TerminalSize(columns: 80, rows: 24)!
        )
        let spoolURL = try XCTUnwrap(descriptor.metadata["outputPath"]).asURL
        try append(Data([0x41, 0x00, 0x42]), to: spoolURL)
        await firstRuntime.shutdown()

        let secondRuntime = TmuxRuntime(
            executor: executor,
            outputDirectory: outputDirectory,
            exitPollIntervalNanoseconds: 10_000_000
        )
        let stream = await secondRuntime.events(for: sessionID)
        try await secondRuntime.adopt(
            sessionID: sessionID,
            descriptor: descriptor,
            size: TerminalSize(columns: 100, rows: 40)!,
            outputOffset: 1
        )

        let event = try await nextOutput(from: stream)
        XCTAssertEqual(event, Data([0x00, 0x42]))
        await secondRuntime.shutdown()
    }

    func testInvalidDirectoryAndMissingSessionAreActionable() async throws {
        let executor = RecordingTmuxExecutor()
        let runtime = TmuxRuntime(executor: executor, outputDirectory: try temporaryDirectory())

        do {
            _ = try await runtime.create(
                sessionID: sessionID,
                workingDirectory: "/path/that/does/not/exist",
                size: TerminalSize(columns: 80, rows: 24)!
            )
            XCTFail("Expected invalid working directory")
        } catch let error as TmuxRuntimeError {
            guard case let .invalidWorkingDirectory(path, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, "/path/that/does/not/exist")
        }

        let descriptor = TerminalRuntimeDescriptor(
            runtime: TmuxRuntime.runtimeName,
            identifier: TmuxSessionNaming.name(for: sessionID),
            metadata: ["outputPath": (try temporaryDirectory().appendingPathComponent("out")).path]
        )
        do {
            try await runtime.adopt(
                sessionID: sessionID,
                descriptor: descriptor,
                size: TerminalSize(columns: 80, rows: 24)!,
                outputOffset: 0
            )
            XCTFail("Expected missing session")
        } catch let error as TmuxRuntimeError {
            guard case let .sessionNotFound(name, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(name, TmuxSessionNaming.name(for: sessionID))
        }
    }

    func testMissingTmuxBinaryIsStructured() async throws {
        let executor = ProcessTmuxCommandExecutor(tmuxPath: "/path/that/does/not/exist")
        let runtime = TmuxRuntime(executor: executor, outputDirectory: try temporaryDirectory())
        do {
            _ = try await runtime.create(
                sessionID: sessionID,
                workingDirectory: try temporaryDirectory().path,
                size: TerminalSize(columns: 80, rows: 24)!
            )
            XCTFail("Expected missing binary")
        } catch let error as TmuxRuntimeError {
            guard case .binaryUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLocalTmuxSmokeWhenAvailable() async throws {
        let executor = ProcessTmuxCommandExecutor()
        do {
            _ = try await executor.execute(arguments: ["-V"])
        } catch let error as TmuxCommandExecutorError {
            if case .binaryNotFound = error {
                throw XCTSkip("本机未安装 tmux")
            }
            throw error
        }

        let outputDirectory = try temporaryDirectory()
        let runtime = TmuxRuntime(
            executor: executor,
            outputDirectory: outputDirectory,
            exitPollIntervalNanoseconds: 20_000_000
        )
        let smokeSessionID = TerminalSessionID()
        let stream = await runtime.events(for: smokeSessionID)
        let descriptor = try await runtime.create(
            sessionID: smokeSessionID,
            workingDirectory: outputDirectory.path,
            size: TerminalSize(columns: 80, rows: 24)!
        )
        defer {
            Task {
                _ = try? await executor.execute(arguments: ["kill-session", "-t", descriptor.identifier])
                await runtime.shutdown()
            }
        }

        let paneEnvironment = try await executor.execute(arguments: [
            "show-environment", "-t", descriptor.identifier,
        ])
        XCTAssertEqual(paneEnvironment.exitCode, 0)
        let values = Dictionary(uniqueKeysWithValues: paneEnvironment.stdoutText
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            })
        XCTAssertEqual(values["COLORTERM"], "truecolor")
        XCTAssertEqual(values["TERM_PROGRAM"], "Warren")
        XCTAssertNil(values["NO_COLOR"])

        try await runtime.write(sessionID: smokeSessionID, data: Data("env\r".utf8))
        let outputURL = try XCTUnwrap(descriptor.metadata["outputPath"]).asURL
        let environmentOutput = try await waitForSpool(
            containing: Data("TERM_PROGRAM=Warren".utf8),
            at: outputURL
        )
        let environmentText = String(decoding: environmentOutput, as: UTF8.self)
        XCTAssertTrue(environmentText.contains("TERM=tmux-256color"))
        XCTAssertTrue(environmentText.contains("COLORTERM=truecolor"))
        XCTAssertFalse(environmentText.contains("\nNO_COLOR="))

        let marker = Data("WARREN_SMOKE_\(UUID().uuidString)".utf8)
        var command = Data("printf '".utf8)
        command.append(marker)
        command.append(Data("'\\n'".utf8))
        try await runtime.write(sessionID: smokeSessionID, data: command + Data([0x0A]))

        let output = try await nextOutput(containing: marker, from: stream)
        XCTAssertTrue(output.range(of: marker) != nil)
    }

    func testLocalTmuxAdapterRestartAdoptsSpoolTail() async throws {
        let executor = ProcessTmuxCommandExecutor()
        do {
            _ = try await executor.execute(arguments: ["-V"])
        } catch let error as TmuxCommandExecutorError {
            if case .binaryNotFound = error {
                throw XCTSkip("本机未安装 tmux")
            }
            throw error
        }

        let outputDirectory = try temporaryDirectory()
        let firstRuntime = TmuxRuntime(
            executor: executor,
            outputDirectory: outputDirectory,
            exitPollIntervalNanoseconds: 20_000_000
        )
        let smokeSessionID = TerminalSessionID()
        let firstStream = await firstRuntime.events(for: smokeSessionID)
        let descriptor = try await firstRuntime.create(
            sessionID: smokeSessionID,
            workingDirectory: outputDirectory.path,
            size: TerminalSize(columns: 80, rows: 24)!
        )
        let outputURL = try XCTUnwrap(descriptor.metadata["outputPath"]).asURL
        defer {
            Task {
                _ = try? await executor.execute(arguments: ["kill-session", "-t", descriptor.identifier])
                await firstRuntime.shutdown()
            }
        }

        let markerBefore = Data("WARREN_RESTART_BEFORE_\(UUID().uuidString)".utf8)
        try await firstRuntime.write(
            sessionID: smokeSessionID,
            data: shellPrintCommand(for: markerBefore)
        )
        _ = try await nextOutput(containing: markerBefore, from: firstStream)
        _ = try await waitForSpool(containing: markerBefore, at: outputURL)
        // Let the login shell finish its prompt redraw before taking the
        // persisted byte offset; no output is sent during this interval.
        try await Task.sleep(nanoseconds: 100_000_000)
        let persistedOffset = UInt64(try Data(contentsOf: outputURL).count)

        await firstRuntime.shutdown()
        let surviving = try await executor.execute(
            arguments: ["has-session", "-t", descriptor.identifier]
        )
        XCTAssertEqual(surviving.exitCode, 0)

        let markerAfter = Data("WARREN_RESTART_AFTER_\(UUID().uuidString)".utf8)
        let inputBuffer = try XCTUnwrap(descriptor.metadata["inputBuffer"])
        let paneTarget = try XCTUnwrap(descriptor.metadata["paneTarget"])
        let load = try await executor.execute(
            arguments: ["load-buffer", "-b", inputBuffer, "-"],
            standardInput: shellPrintCommand(for: markerAfter)
        )
        XCTAssertEqual(load.exitCode, 0)
        let paste = try await executor.execute(
            arguments: ["paste-buffer", "-b", inputBuffer, "-d", "-t", paneTarget]
        )
        XCTAssertEqual(paste.exitCode, 0)
        _ = try await waitForSpool(containing: markerAfter, at: outputURL)

        let secondRuntime = TmuxRuntime(
            executor: executor,
            outputDirectory: outputDirectory,
            exitPollIntervalNanoseconds: 20_000_000
        )
        let secondStream = await secondRuntime.events(for: smokeSessionID)
        try await secondRuntime.adopt(
            sessionID: smokeSessionID,
            descriptor: descriptor,
            size: TerminalSize(columns: 80, rows: 24)!,
            outputOffset: persistedOffset
        )
        let recovered = try await nextOutput(containing: markerAfter, from: secondStream)
        XCTAssertNotNil(recovered.range(of: markerAfter))
        await secondRuntime.shutdown()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-tmux-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private func shellPrintCommand(for marker: Data) -> Data {
        var command = Data("printf '".utf8)
        command.append(marker)
        command.append(Data("\\n'".utf8))
        command.append(0x0A)
        return command
    }

    private func waitForSpool(containing expected: Data, at url: URL) async throws -> Data {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: url), data.range(of: expected) != nil {
                return data
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw RuntimeTestError.timeout
    }

    private func nextOutput(from stream: AsyncStream<TerminalRuntimeEvent>) async throws -> Data {
        try await nextOutput(containing: nil, from: stream)
    }

    private func nextOutput(
        containing expected: Data?,
        from stream: AsyncStream<TerminalRuntimeEvent>
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                while let event = await iterator.next() {
                    if case let .output(_, data) = event,
                       expected == nil || data.range(of: expected!) != nil {
                        return data
                    }
                }
                throw RuntimeTestError.timeout
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw RuntimeTestError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

private enum RuntimeTestError: Error {
    case timeout
}

private actor RecordingTmuxExecutor: TmuxCommandExecuting {
    struct Call: Sendable, Equatable {
        let arguments: [String]
        let standardInput: Data?
    }

    private(set) var calls: [Call] = []
    private var sessions: Set<String> = []

    func execute(arguments: [String], standardInput: Data?) async throws -> TmuxCommandResult {
        calls.append(Call(arguments: arguments, standardInput: standardInput))
        guard let command = arguments.first else {
            return TmuxCommandResult(exitCode: 0)
        }
        switch command {
        case "has-session":
            let name = arguments.last ?? ""
            return TmuxCommandResult(exitCode: sessions.contains(name) ? 0 : 1)
        case "list-sessions":
            let output = sessions.sorted().joined(separator: "\n")
            return TmuxCommandResult(
                stdout: Data((output.isEmpty ? output : output + "\n").utf8),
                exitCode: sessions.isEmpty ? 1 : 0
            )
        case "new-session":
            if let index = arguments.firstIndex(of: "-s"), arguments.indices.contains(index + 1) {
                sessions.insert(arguments[index + 1])
            }
            return TmuxCommandResult(exitCode: 0)
        case "display-message":
            return TmuxCommandResult(stdout: Data("%1\n".utf8), exitCode: 0)
        case "kill-session":
            if let index = arguments.firstIndex(of: "-t"), arguments.indices.contains(index + 1) {
                sessions.remove(arguments[index + 1])
            }
            return TmuxCommandResult(exitCode: 0)
        default:
            return TmuxCommandResult(exitCode: 0)
        }
    }
}

private actor YieldingTmuxExecutor: TmuxCommandExecuting {
    private(set) var calls: [RecordingTmuxExecutor.Call] = []
    private var sessions: Set<String> = []
    private let blockFirstLoad: Bool
    private var firstLoadStarted = false
    private var firstLoadReleased = false

    init(blockFirstLoad: Bool = false) {
        self.blockFirstLoad = blockFirstLoad
    }

    func execute(arguments: [String], standardInput: Data?) async throws -> TmuxCommandResult {
        calls.append(.init(arguments: arguments, standardInput: standardInput))
        await Task.yield()
        guard let command = arguments.first else { return TmuxCommandResult(exitCode: 0) }
        if command == "load-buffer", blockFirstLoad, !firstLoadStarted {
            firstLoadStarted = true
            while !firstLoadReleased {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        switch command {
        case "has-session":
            return TmuxCommandResult(exitCode: sessions.contains(arguments.last ?? "") ? 0 : 1)
        case "list-sessions":
            let output = sessions.sorted().joined(separator: "\n")
            return TmuxCommandResult(
                stdout: Data((output.isEmpty ? output : output + "\n").utf8),
                exitCode: sessions.isEmpty ? 1 : 0
            )
        case "new-session":
            if let index = arguments.firstIndex(of: "-s"), arguments.indices.contains(index + 1) {
                sessions.insert(arguments[index + 1])
            }
            return TmuxCommandResult(exitCode: 0)
        case "display-message":
            return TmuxCommandResult(stdout: Data("%1\n".utf8), exitCode: 0)
        default:
            return TmuxCommandResult(exitCode: 0)
        }
    }

    func waitUntilFirstLoadStarts() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !firstLoadStarted, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard firstLoadStarted else { throw RuntimeTestError.timeout }
    }

    func releaseFirstLoad() {
        firstLoadReleased = true
    }
}

private extension String {
    var asURL: URL { URL(fileURLWithPath: self) }
}
