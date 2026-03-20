import Foundation

public actor TmuxBackend: TmuxControlling {

    private let runner: TmuxCommandRunner
    private var lastSnapshot: [TmuxSession] = []
    private var pollingTask: Task<Void, Never>?
    private var onChange: (([TmuxSession]) -> Void)?
    private let pollingInterval: UInt64 = 5_000_000_000

    public init(runner: TmuxCommandRunner = TmuxCommandRunner()) {
        self.runner = runner
    }

    // MARK: - Polling

    public func setOnChange(_ handler: @escaping @Sendable ([TmuxSession]) -> Void) {
        self.onChange = handler
    }

    public func startPolling() {
        guard pollingTask == nil else { return }
        let interval = self.pollingInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                guard let self = self else { break }
                await self.pollOnce()
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func pollOnce() async {
        do {
            let sessions = try await scanAll()
            if sessions != lastSnapshot {
                lastSnapshot = sessions
                onChange?(sessions)
            }
        } catch {
            // Polling failures are silently ignored; the next tick will retry.
        }
    }

    public func refreshNow() async {
        await pollOnce()
    }

    // MARK: - TmuxControlling (Phase 1)

    public func isAvailable() async -> Bool {
        await runner.isAvailable()
    }

    public func scanAll() async throws -> [TmuxSession] {
        let sessionsOutput = try await runner.run(
            "list-sessions", "-F", TmuxParser.sessionFormat
        )
        var sessions = TmuxParser.parseSessions(sessionsOutput)

        for i in sessions.indices {
            let windowsOutput = try await runner.run(
                "list-windows", "-t", sessions[i].sessionId,
                "-F", TmuxParser.windowFormat
            )
            sessions[i].windows = TmuxParser.parseWindows(windowsOutput)

            for j in sessions[i].windows.indices {
                let target = "\(sessions[i].sessionId):\(sessions[i].windows[j].windowId)"
                let panesOutput = try await runner.run(
                    "list-panes", "-t", target,
                    "-F", TmuxParser.paneFormat
                )
                sessions[i].windows[j].panes = TmuxParser.parsePanes(panesOutput)
            }
        }

        return sessions
    }

    public func createSession(name: String, cwd: String) async throws -> TmuxSession {
        let output = try await runner.run(
            "new-session", "-d", "-s", name, "-c", cwd,
            "-P", "-F", TmuxParser.sessionFormat
        )

        let sessions = TmuxParser.parseSessions(output)
        guard let session = sessions.first else {
            throw TmuxError.executionFailed(
                command: "new-session",
                exitCode: -1,
                stderr: "Failed to parse created session"
            )
        }
        return session
    }

    public func selectWindow(sessionId: String, windowId: String) async throws {
        _ = try await runner.run(
            "select-window", "-t", "\(sessionId):\(windowId)"
        )
    }

    public func killSession(id: String) async throws {
        _ = try await runner.run(
            "kill-session", "-t", id
        )
    }

    public func renameWindow(sessionId: String, windowId: String, newName: String) async throws {
        _ = try await runner.run(
            "rename-window", "-t", "\(sessionId):\(windowId)", newName
        )
    }

    public func createWindow(sessionId: String, name: String?, cwd: String?) async throws -> TmuxWindow {
        var args: [String] = ["new-window", "-t", sessionId, "-P", "-F", TmuxParser.windowFormat]
        if let name {
            args.append(contentsOf: ["-n", name])
        }
        if let cwd {
            args.append(contentsOf: ["-c", cwd])
        }
        let output = try await runner.run(args)
        let windows = TmuxParser.parseWindows(output)
        guard let window = windows.first else {
            throw TmuxError.executionFailed(
                command: "new-window",
                exitCode: -1,
                stderr: "Failed to parse created window"
            )
        }
        return window
    }

    public func sendKeys(sessionId: String, paneId: String, keys: String) async throws {
        _ = try await runner.run(
            "send-keys", "-t", "\(sessionId):\(paneId)", keys, "Enter"
        )
    }

    public func splitPane(sessionId: String, paneId: String, horizontal: Bool, cwd: String?) async throws -> TmuxPane {
        let target = paneId.isEmpty ? sessionId : paneId
        var args: [String] = [
            "split-window",
            horizontal ? "-h" : "-v",
            "-t", target,
            "-P", "-F", TmuxParser.paneFormat,
        ]
        if let cwd {
            args.append(contentsOf: ["-c", cwd])
        }
        let output = try await runner.run(args)
        let panes = TmuxParser.parsePanes(output)
        guard let pane = panes.first else {
            throw TmuxError.executionFailed(
                command: "split-window",
                exitCode: -1,
                stderr: "Failed to parse created pane"
            )
        }
        return pane
    }

    public func killWindow(sessionId: String, windowId: String) async throws {
        _ = try await runner.run(
            "kill-window", "-t", "\(sessionId):\(windowId)"
        )
    }

    public func killPane(sessionId: String, paneId: String) async throws {
        _ = try await runner.run(
            "kill-pane", "-t", paneId
        )
    }

    public func setServerOption(option: String, value: String) async throws {
        _ = try await runner.run("set-option", "-s", option, value)
    }

    public func setOption(sessionId: String?, option: String, value: String) async throws {
        if let sessionId {
            _ = try await runner.run("set-option", "-t", sessionId, option, value)
        } else {
            _ = try await runner.run("set-option", "-g", option, value)
        }
    }

    public func setWindowOption(global: Bool, target: String?, option: String, value: String) async throws {
        if global {
            _ = try await runner.run("set-option", "-gw", option, value)
        } else if let target {
            _ = try await runner.run("set-option", "-w", "-t", target, option, value)
        }
    }

    public func capturePaneOutput(paneId: String, lineCount: Int) async throws -> String {
        try await runner.run(
            "capture-pane", "-p", "-t", paneId, "-S", "-\(lineCount)"
        )
    }

    public func navigatePane(sessionId: String, direction: PaneDirection) async throws {
        if let target = direction.selectTarget {
            _ = try await runner.run("select-pane", "-t", "\(sessionId):.\(target)")
        } else {
            _ = try await runner.run("select-pane", "-t", sessionId, "-\(direction.rawValue)")
        }
    }

    public func resizePane(sessionId: String, direction: PaneDirection, amount: Int) async throws {
        _ = try await runner.run(
            "resize-pane", "-t", sessionId, "-\(direction.rawValue)", "\(amount)"
        )
    }

    public func togglePaneZoom(sessionId: String) async throws {
        _ = try await runner.run("resize-pane", "-t", sessionId, "-Z")
    }

    public func equalizePanes(sessionId: String) async throws {
        _ = try await runner.run("select-layout", "-t", sessionId, "tiled")
    }

    public func refreshClients() async throws {
        let output = try await runner.run("list-clients", "-F", "#{client_name}")
        let clients = output.split(separator: "\n").map(String.init)
        for client in clients {
            _ = try? await runner.run("refresh-client", "-t", client)
        }
    }
}
