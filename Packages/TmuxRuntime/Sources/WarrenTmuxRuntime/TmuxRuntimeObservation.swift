import Foundation
import WarrenDomain
import WarrenHost

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
            startLifecycleMonitorIfNeeded()
        } catch {
            await removeManagedSession(sessionID)
            throw error
        }
    }

    /// One Runtime-level watcher observes every managed session with one tmux
    /// command per tick. Its process cost therefore stays constant as session
    /// count grows.
    func startLifecycleMonitorIfNeeded() {
        guard lifecycleMonitorTask == nil,
              sessions.values.contains(where: \.isRunning) else { return }
        let interval = exitPollIntervalNanoseconds
        lifecycleMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if !(await self.observeManagedSessions()) {
                    return
                }
            }
        }
    }

    /// Returns false when no live managed sessions remain and the watcher can
    /// stop. A failed tmux invocation is treated as transient.
    func observeManagedSessions() async -> Bool {
        let running = sessions.filter { $0.value.isRunning }
        guard !running.isEmpty else {
            lifecycleMonitorTask = nil
            return false
        }
        guard let liveNames = await probeManagedSessionNames() else { return true }
        for (sessionID, managed) in running where !liveNames.contains(managed.descriptor.identifier) {
            finishSession(sessionID: sessionID, exitCode: nil)
        }
        if !sessions.values.contains(where: \.isRunning) {
            lifecycleMonitorTask = nil
            return false
        }
        return true
    }

    func receiveOutput(_ data: Data, for sessionID: TerminalSessionID) {
        guard sessions[sessionID]?.isRunning == true else { return }
        broadcast(.output(sessionID: sessionID, data: data), for: sessionID)
    }

    func finishSession(sessionID: TerminalSessionID, exitCode: Int?) {
        guard var managed = sessions[sessionID], managed.isRunning else { return }
        managed.isRunning = false
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
