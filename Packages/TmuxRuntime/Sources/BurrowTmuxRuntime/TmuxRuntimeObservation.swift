import Foundation
import BurrowDomain
import BurrowHost

extension TmuxRuntime {
    /// Installs the append-only spool watcher before opening the tmux pipe.
    /// This ordering narrows the only unavoidable race (tmux creates its
    /// first pane before `pipe-pane` can be issued) and ensures all bytes
    /// written after the pipe is open are observed from disk.
    func install(
        sessionID: TerminalSessionID,
        descriptor: TerminalRuntimeDescriptor,
        paneTarget: String,
        spoolURL: URL,
        inputBufferName: String,
        outputOffset: UInt64,
        pipeOnlyIfMissing: Bool,
        launchInteractiveShell: Bool,
        shellPath: String?
    ) async throws {
        let watcher = try OutputSpoolWatcher(
            fileURL: spoolURL,
            initialOffset: outputOffset
        ) { [weak self] data in
            Task { [weak self] in
                await self?.receiveOutput(data, for: sessionID)
            }
        }
        watcher.start()

        sessions[sessionID] = ManagedSession(
            descriptor: descriptor,
            paneTarget: paneTarget,
            spoolURL: spoolURL,
            inputBufferName: inputBufferName,
            watcher: watcher,
            monitorTask: nil,
            isRunning: true
        )

        do {
            var arguments = ["pipe-pane"]
            if pipeOnlyIfMissing { arguments.append("-o") }
            arguments.append(contentsOf: [
                "-O", "-t", paneTarget,
                "cat >> \(Self.shellQuote(spoolURL.path))",
            ])
            try await requireSuccess(
                arguments,
                recovery: "Ensure the tmux pane can create an output pipe; if permissions or tmux configuration block it, retry the session."
            )
            if launchInteractiveShell, let shellPath {
                try await requireSuccess(
                    ["respawn-pane", "-k", "-t", paneTarget, shellPath, "-l"],
                    recovery: "Ensure the login shell can start; check SHELL and retry."
                )
            }
            startMonitor(sessionID: sessionID, name: descriptor.identifier)
        } catch {
            await removeManagedSession(sessionID)
            throw error
        }
    }

    func startMonitor(sessionID: TerminalSessionID, name: String) {
        guard var managed = sessions[sessionID], managed.isRunning else { return }
        managed.monitorTask?.cancel()
        let interval = exitPollIntervalNanoseconds
        managed.monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                let alive = await self.probeSession(name: name)
                if !alive {
                    await self.finishSession(sessionID: sessionID, exitCode: nil)
                    return
                }
            }
        }
        sessions[sessionID] = managed
    }

    func receiveOutput(_ data: Data, for sessionID: TerminalSessionID) {
        guard sessions[sessionID]?.isRunning == true else { return }
        broadcast(.output(sessionID: sessionID, data: data), for: sessionID)
    }

    func finishSession(sessionID: TerminalSessionID, exitCode: Int?) {
        guard var managed = sessions[sessionID], managed.isRunning else { return }
        managed.isRunning = false
        managed.monitorTask?.cancel()
        managed.monitorTask = nil
        managed.watcher.cancel()
        sessions[sessionID] = managed
        broadcast(.exited(sessionID: sessionID, exitCode: exitCode), for: sessionID)
    }

    func broadcast(_ event: TerminalRuntimeEvent, for sessionID: TerminalSessionID) {
        guard let sessionContinuations = continuations[sessionID] else { return }
        for continuation in sessionContinuations.values {
            continuation.yield(event)
        }
        if case .exited = event {
            for continuation in sessionContinuations.values {
                continuation.finish()
            }
            continuations[sessionID] = nil
        }
    }
}
