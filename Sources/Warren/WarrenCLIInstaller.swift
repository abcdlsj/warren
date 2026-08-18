import Foundation

/// Installs the CLI that is shipped inside Warren.app.
///
/// Release archives contain the CLI next to the desktop executable, but
/// launching an app from Finder does not run the repository's install script.
/// Keeping this small installer in the app gives archive users the same
/// user-level CLI installation path as a source checkout.
struct WarrenCLIInstaller {
    struct InstallationResult {
        let executableURL: URL
        let installDirectory: URL
        let pathProfileURL: URL?
    }

    enum InstallationError: LocalizedError {
        case bundledCLIUnavailable
        case fileSystem(Error)

        var errorDescription: String? {
            switch self {
            case .bundledCLIUnavailable:
                return "The Warren CLI is not available in this application bundle."
            case let .fileSystem(error):
                return "Could not install the Warren CLI: \(error.localizedDescription)"
            }
        }
    }

    private static let bundledCLIName = "warren-cli"
    private static let installedCLIName = "warren"
    private static let defaultInstallDirectory = ".local/bin"
    private static let pathMarker = "# Warren CLI"

    /// Installs the bundled CLI only when the user-level command is missing.
    /// Returning `nil` keeps normal subsequent launches quiet and cheap while
    /// still repairing an installation if the user removes the command.
    static func installIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        bundleExecutableURL: URL? = Bundle.main.executableURL,
        fileManager: FileManager = .default
    ) throws -> InstallationResult? {
        let directory = installDirectory(
            environment: environment,
            homeDirectory: homeDirectory
        )
        let destinationURL = directory.appendingPathComponent(installedCLIName)
        if fileManager.isExecutableFile(atPath: destinationURL.path) {
            let pathProfileURL = try ensurePathEntry(
                installDirectory: directory,
                homeDirectory: homeDirectory,
                environment: environment,
                fileManager: fileManager
            )
            guard let pathProfileURL else { return nil }
            return InstallationResult(
                executableURL: destinationURL,
                installDirectory: directory,
                pathProfileURL: pathProfileURL
            )
        }
        return try install(
            environment: environment,
            homeDirectory: homeDirectory,
            currentDirectory: currentDirectory,
            bundleExecutableURL: bundleExecutableURL,
            fileManager: fileManager
        )
    }

    static func install(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        bundleExecutableURL: URL? = Bundle.main.executableURL,
        fileManager: FileManager = .default
    ) throws -> InstallationResult {
        guard let sourceURL = bundledCLIURL(
            environment: environment,
            currentDirectory: currentDirectory,
            bundleExecutableURL: bundleExecutableURL,
            fileManager: fileManager
        ) else {
            throw InstallationError.bundledCLIUnavailable
        }

        let installDirectory = installDirectory(
            environment: environment,
            homeDirectory: homeDirectory
        )
        let destinationURL = installDirectory.appendingPathComponent(installedCLIName)

        do {
            try fileManager.createDirectory(
                at: installDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            try copyExecutable(
                from: sourceURL,
                to: destinationURL,
                fileManager: fileManager
            )
            let pathProfileURL = try ensurePathEntry(
                installDirectory: installDirectory,
                homeDirectory: homeDirectory,
                environment: environment,
                fileManager: fileManager
            )
            return InstallationResult(
                executableURL: destinationURL,
                installDirectory: installDirectory,
                pathProfileURL: pathProfileURL
            )
        } catch let error as InstallationError {
            throw error
        } catch {
            throw InstallationError.fileSystem(error)
        }
    }

    private static func bundledCLIURL(
        environment: [String: String],
        currentDirectory: URL,
        bundleExecutableURL: URL?,
        fileManager: FileManager
    ) -> URL? {
        var candidates: [URL] = []
        if let configured = environment["WARREN_CLI_PATH"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }

        var executableDirectories: [URL] = []
        if let bundleExecutableURL {
            executableDirectories.append(bundleExecutableURL.deletingLastPathComponent())
        }
        if let commandPath = CommandLine.arguments.first, !commandPath.isEmpty {
            executableDirectories.append(
                URL(fileURLWithPath: commandPath).deletingLastPathComponent()
            )
        }
        for directory in executableDirectories {
            candidates.append(directory.appendingPathComponent(bundledCLIName))
            candidates.append(directory.appendingPathComponent(installedCLIName))
        }

        // This keeps `swift run Warren` and local debug builds useful too;
        // release apps normally resolve the sibling inside Contents/MacOS.
        candidates.append(currentDirectory.appendingPathComponent(".build/warren-cli"))

        var seenPaths = Set<String>()
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            guard seenPaths.insert(standardized.path).inserted else { continue }
            if fileManager.isExecutableFile(atPath: standardized.path) {
                return standardized
            }
        }
        return nil
    }

    private static func installDirectory(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        if let configured = environment["WARREN_CLI_INSTALL_DIRECTORY"], !configured.isEmpty {
            return URL(fileURLWithPath: configured).standardizedFileURL
        }
        return homeDirectory
            .appendingPathComponent(defaultInstallDirectory, isDirectory: true)
            .standardizedFileURL
    }

    private static func copyExecutable(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".warren-cli-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: temporaryURL.path
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    /// Adds the install directory to a shell startup file when the app was
    /// launched without the user's interactive shell PATH.
    private static func ensurePathEntry(
        installDirectory: URL,
        homeDirectory: URL,
        environment: [String: String],
        fileManager: FileManager
    ) throws -> URL? {
        let installPath = installDirectory.standardizedFileURL.path
        let currentPath = environment["PATH"] ?? ""
        if currentPath.split(separator: ":").contains(where: {
            expandedPath(String($0), homeDirectory: homeDirectory) == installPath
        }) {
            return nil
        }

        let shellProfileURL = shellProfileURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        let existingContents = (try? String(contentsOf: shellProfileURL, encoding: .utf8)) ?? ""
        if existingContents.contains(installPath)
            || existingContents.contains("$HOME/.local/bin")
            || existingContents.contains("~/.local/bin") {
            return nil
        }

        do {
            try fileManager.createDirectory(
                at: shellProfileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let snippet = pathSnippet(
                installDirectory: installDirectory,
                homeDirectory: homeDirectory,
                environment: environment
            )
            try (existingContents + snippet).write(
                to: shellProfileURL,
                atomically: true,
                encoding: .utf8
            )
            return shellProfileURL
        } catch {
            throw InstallationError.fileSystem(error)
        }
    }

    private static func shellProfileURL(
        homeDirectory: URL,
        environment: [String: String]
    ) -> URL {
        let shell = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh")
            .lastPathComponent
        switch shell {
        case "bash":
            return homeDirectory.appendingPathComponent(".bash_profile")
        case "fish":
            return homeDirectory
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("fish", isDirectory: true)
                .appendingPathComponent("config.fish")
        default:
            return homeDirectory.appendingPathComponent(".zprofile")
        }
    }

    private static func pathSnippet(
        installDirectory: URL,
        homeDirectory: URL,
        environment: [String: String]
    ) -> String {
        let shell = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh")
            .lastPathComponent
        let pathExpression: String
        let defaultDirectory = homeDirectory
            .appendingPathComponent(defaultInstallDirectory, isDirectory: true)
            .standardizedFileURL
        if installDirectory.standardizedFileURL == defaultDirectory {
            pathExpression = "$HOME/.local/bin"
        } else {
            let escapedPath = installDirectory.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            pathExpression = "\"\(escapedPath)\""
        }

        if shell == "fish" {
            return "\n\(pathMarker)\nset -gx PATH \(pathExpression) $PATH\n"
        }
        if installDirectory.standardizedFileURL == defaultDirectory {
            return "\n\(pathMarker)\nexport PATH=\"$HOME/.local/bin:$PATH\"\n"
        }
        return "\n\(pathMarker)\nexport PATH=\(pathExpression):$PATH\n"
    }

    private static func expandedPath(_ value: String, homeDirectory: URL) -> String {
        var expanded = value
        if expanded == "~" {
            expanded = homeDirectory.path
        } else if expanded.hasPrefix("~/") {
            expanded = homeDirectory.appendingPathComponent(String(expanded.dropFirst(2))).path
        }
        expanded = expanded.replacingOccurrences(of: "$HOME", with: homeDirectory.path)
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
