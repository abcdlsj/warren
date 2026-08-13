import Foundation
import WarrenDomain

/// Actionable failures from the tmux runtime adapter.
public enum TmuxRuntimeError: Error, Equatable, Sendable, LocalizedError {
    case binaryUnavailable(searchPaths: [String], recovery: String)
    case invalidWorkingDirectory(path: String, recovery: String)
    case sessionAlreadyExists(name: String, recovery: String)
    case sessionNotFound(name: String, recovery: String)
    case descriptorInvalid(reason: String, recovery: String)
    case outputSpoolUnavailable(path: String, reason: String, recovery: String)
    case outputOffsetUnavailable(path: String, offset: UInt64, fileSize: UInt64, recovery: String)
    case commandFailed(arguments: [String], exitCode: Int32, stderr: String, recovery: String)

    public var errorDescription: String? {
        switch self {
        case let .binaryUnavailable(searchPaths, recovery):
            return recovery + " Checked paths: " + searchPaths.joined(separator: ", ") + "."
        case let .invalidWorkingDirectory(path, recovery):
            return "Invalid working directory (" + path + "). " + recovery
        case let .sessionAlreadyExists(name, recovery):
            return "tmux session already exists (" + name + "). " + recovery
        case let .sessionNotFound(name, recovery):
            return "tmux session not found (" + name + "). " + recovery
        case let .descriptorInvalid(reason, recovery):
            return "Invalid runtime adoption descriptor: " + reason + ". " + recovery
        case let .outputSpoolUnavailable(path, reason, recovery):
            return "Cannot open terminal output spool (" + path + "): " + reason + ". " + recovery
        case let .outputOffsetUnavailable(path, offset, fileSize, recovery):
            return "Terminal output spool (" + path + ") is only " + String(fileSize) +
                " bytes, but the recovery offset is " + String(offset) + ". " + recovery
        case let .commandFailed(arguments, exitCode, stderr, recovery):
            let command = "tmux " + arguments.joined(separator: " ")
            return "Command failed (exit " + String(exitCode) + "): " + (stderr.isEmpty ? command : stderr) + ". " + recovery
        }
    }

    static func fromExecutor(_ error: Error) -> Self? {
        guard let error = error as? TmuxCommandExecutorError else { return nil }
        switch error {
        case let .binaryNotFound(searchPaths):
            return .binaryUnavailable(
                searchPaths: searchPaths,
                recovery: "Install tmux (for example `brew install tmux`), or set tmuxPath on ProcessTmuxCommandExecutor."
            )
        case let .launchFailed(path, reason):
            return .commandFailed(
                arguments: [],
                exitCode: -1,
                stderr: path + ": " + reason,
                recovery: "Check tmux file permissions, architecture, and the macOS runtime environment."
            )
        }
    }
}
