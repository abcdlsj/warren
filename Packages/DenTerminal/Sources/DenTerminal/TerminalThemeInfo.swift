import AppKit

/// Small theme bundle shared between AppKit chrome and the terminal host.
public struct TerminalThemeInfo: Sendable {
    public let background: NSColor
    public let foreground: NSColor
    public let cursor: NSColor
    public let isDark: Bool

    public init(background: NSColor, foreground: NSColor, cursor: NSColor, isDark: Bool) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.isDark = isDark
    }

    public static let slate = TerminalThemeInfo(
        background: NSColor(srgbRed: 0x10 / 255.0, green: 0x16 / 255.0, blue: 0x1d / 255.0, alpha: 1),
        foreground: NSColor(srgbRed: 0xe3 / 255.0, green: 0xeb / 255.0, blue: 0xf5 / 255.0, alpha: 1),
        cursor: NSColor(srgbRed: 0x7e / 255.0, green: 0xca / 255.0, blue: 0xff / 255.0, alpha: 1),
        isDark: true
    )

    public static let tango = slate
    public static let fallback = slate
}
