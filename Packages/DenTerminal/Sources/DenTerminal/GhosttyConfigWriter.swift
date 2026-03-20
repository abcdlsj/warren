import Foundation

/// Writes minimal Den-specific overrides to a Ghostty config file.
/// User preferences (font, theme, cursor, keybindings, etc.) come from
/// Ghostty's own config at `~/.config/ghostty/config`.
@MainActor
enum GhosttyConfigWriter {

    private static let configDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Den", isDirectory: true)
    }()

    static let configPath: URL = configDir.appendingPathComponent("ghostty-den-overrides.conf")

    /// Write Den-specific embedding overrides. Returns the file path.
    @discardableResult
    static func write() -> String {
        let lines: [String] = [
            "# Den embedding overrides — do not edit manually.",
            "# User preferences belong in ~/.config/ghostty/config",
            "window-decoration = false",
            "confirm-close-surface = false",
            "quit-after-last-window-closed = false",
            "# Override ghostty's default xterm-ghostty for tmux compatibility",
            "term = xterm-256color",
        ]

        let content = lines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? content.write(to: configPath, atomically: true, encoding: .utf8)
        return configPath.path
    }
}
