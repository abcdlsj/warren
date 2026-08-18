import Foundation
import XCTest
@testable import Warren

final class WarrenCLIInstallerTests: XCTestCase {
    func testInstallsBundledCLIAndAddsZshPathEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-cli-installer-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("warren-cli")
        try Data("test cli".utf8).write(to: sourceURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sourceURL.path
        )

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let result = try WarrenCLIInstaller.install(
            environment: [
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/zsh",
                "WARREN_CLI_PATH": sourceURL.path,
            ],
            homeDirectory: homeDirectory,
            currentDirectory: root,
            bundleExecutableURL: nil,
            fileManager: fileManager
        )

        XCTAssertEqual(
            result.executableURL.path,
            homeDirectory.appendingPathComponent(".local/bin/warren").path
        )
        XCTAssertTrue(fileManager.isExecutableFile(atPath: result.executableURL.path))
        let profileURL = try XCTUnwrap(result.pathProfileURL)
        XCTAssertEqual(profileURL.lastPathComponent, ".zprofile")
        let profile = try String(contentsOf: profileURL, encoding: .utf8)
        XCTAssertTrue(profile.contains("export PATH=\"$HOME/.local/bin:$PATH\""))
    }

    func testDoesNotDuplicateAnExistingPathEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-cli-installer-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("warren-cli")
        try Data("test cli".utf8).write(to: sourceURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sourceURL.path
        )

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let installDirectory = homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
        let result = try WarrenCLIInstaller.install(
            environment: [
                "PATH": "/usr/bin:\(installDirectory.path)",
                "SHELL": "/bin/zsh",
                "WARREN_CLI_PATH": sourceURL.path,
            ],
            homeDirectory: homeDirectory,
            currentDirectory: root,
            bundleExecutableURL: nil,
            fileManager: fileManager
        )

        XCTAssertNil(result.pathProfileURL)
        XCTAssertFalse(fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(".zprofile").path))
    }

    func testInstallIfNeededLeavesAnExistingCLIUntouched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-cli-installer-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let installDirectory = homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
        try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let installedURL = installDirectory.appendingPathComponent("warren")
        try Data("existing cli".utf8).write(to: installedURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installedURL.path
        )

        let result = try WarrenCLIInstaller.installIfNeeded(
            environment: [
                "PATH": installDirectory.path,
                "SHELL": "/bin/zsh",
            ],
            homeDirectory: homeDirectory,
            currentDirectory: root,
            bundleExecutableURL: nil,
            fileManager: fileManager
        )

        XCTAssertNil(result)
        XCTAssertEqual(try String(contentsOf: installedURL, encoding: .utf8), "existing cli")
    }
}
