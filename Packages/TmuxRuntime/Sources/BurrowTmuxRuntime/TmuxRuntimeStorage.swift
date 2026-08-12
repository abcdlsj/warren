import Foundation
import BurrowDomain
import BurrowHost

extension TmuxRuntime {
    static var interactiveShellPath: String {
        let configured = ProcessInfo.processInfo.environment["SHELL"]
        if let configured, FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        return "/bin/zsh"
    }

    func validateWorkingDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path) else {
            throw TmuxRuntimeError.invalidWorkingDirectory(
                path: path,
                recovery: "Select an existing, readable folder before creating a terminal session."
            )
        }
    }

    func prepareSpool(for name: String) throws -> URL {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw TmuxRuntimeError.outputSpoolUnavailable(
                path: outputDirectory.path,
                reason: String(describing: error),
                recovery: "Check Burrow's write access to Application Support."
            )
        }
        let url = outputDirectory.appendingPathComponent("\(name).out", isDirectory: false)
        do {
            try Data().write(to: url, options: .atomic)
        } catch {
            throw TmuxRuntimeError.outputSpoolUnavailable(
                path: url.path,
                reason: String(describing: error),
                recovery: "Check Burrow's write access to the output directory."
            )
        }
        return url
    }

    func spoolURL(from descriptor: TerminalRuntimeDescriptor) throws -> URL {
        if let path = descriptor.metadata["outputPath"], !path.isEmpty {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.isFileURL, url.path.hasPrefix("/") else {
                throw TmuxRuntimeError.descriptorInvalid(
                    reason: "outputPath is not an absolute local file path.",
                    recovery: "Use the descriptor returned by TmuxRuntime.create for adoption."
                )
            }
            return url
        }
        return outputDirectory.appendingPathComponent("\(descriptor.identifier).out", isDirectory: false)
    }

    func descriptorWithPane(
        _ descriptor: TerminalRuntimeDescriptor,
        paneTarget: String
    ) -> TerminalRuntimeDescriptor {
        var metadata = descriptor.metadata
        metadata["paneTarget"] = paneTarget
        return TerminalRuntimeDescriptor(
            runtime: descriptor.runtime,
            identifier: descriptor.identifier,
            metadata: metadata
        )
    }

    func clearEndedStateOrReject(
        sessionID: TerminalSessionID,
        name: String
    ) async throws {
        if let managed = sessions[sessionID] {
            if managed.isRunning {
                throw TmuxRuntimeError.sessionAlreadyExists(
                    name: name,
                    recovery: "That Host session is already bound to a runtime; reuse it instead of creating another."
                )
            }
            await removeManagedSession(sessionID)
        }
    }

    func removeManagedSession(_ sessionID: TerminalSessionID) async {
        writeTails.removeValue(forKey: sessionID)?.completion.cancel()
        guard let managed = sessions.removeValue(forKey: sessionID) else { return }
        managed.monitorTask?.cancel()
        managed.watcher.cancel()
    }

    func bestEffortKill(name: String) async {
        _ = try? await executor.execute(arguments: ["kill-session", "-t", name], standardInput: nil)
    }

    func normalize(_ error: Error) -> Error {
        if let error = error as? TmuxRuntimeError { return error }
        if let mapped = TmuxRuntimeError.fromExecutor(error) { return mapped }
        return error
    }

    func removeContinuation(_ token: UUID, for sessionID: TerminalSessionID) {
        continuations[sessionID]?[token] = nil
        if continuations[sessionID]?.isEmpty == true {
            continuations[sessionID] = nil
        }
    }

    static func inputBufferName(for sessionID: TerminalSessionID) -> String {
        "burrow-input-\(sessionID.description)"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
