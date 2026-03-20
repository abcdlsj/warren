import Foundation

/// User-configurable settings loaded from `~/.config/den/config.json`.
/// Invalid files fall back to defaults so configuration never blocks launch.
public struct DenConfiguration: Codable, Sendable {

    // MARK: - Sidebar

    public var sidebarMinWidth: Double
    public var sidebarMaxWidth: Double
    public var sidebarFontSize: Double

    // MARK: - Terminal

    public var terminalFontFamily: String
    public var terminalFontSize: Double

    // MARK: - Title Bar

    public var titleBarHeight: Double

    // MARK: - Theme

    public var themeBackground: String
    public var themeText: String
    public var themeCursor: String

    // MARK: - Defaults

    public static let `default` = DenConfiguration(
        sidebarMinWidth: 220,
        sidebarMaxWidth: 500,
        sidebarFontSize: 13,
        terminalFontFamily: "Menlo",
        terminalFontSize: 14,
        titleBarHeight: 28,
        themeBackground: "#2e3436",
        themeText: "#d3d7cf",
        themeCursor: "#d3d7cf"
    )

    // MARK: - Loading

    public static func load() -> DenConfiguration {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/den/config.json")

        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return .default
        }

        do {
            let data = try Data(contentsOf: configPath)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(DenConfiguration.self, from: data)
        } catch {
            // Configuration errors are treated as non-fatal.
            return .default
        }
    }
}
