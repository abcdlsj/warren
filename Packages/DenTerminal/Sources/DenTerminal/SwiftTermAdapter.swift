import AppKit
@preconcurrency import SwiftTerm

/// `TerminalHost` implementation backed by SwiftTerm's local process terminal view.
@MainActor
public final class SwiftTermAdapter: TerminalHost {

    public var themeInfo: TerminalThemeInfo

    public init() {
        self.themeInfo = .slate
    }

    public func createSurface(command: String, workingDirectory: String) -> NSView {
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Keep the embedded terminal visually aligned with Den's dark chrome.
        terminal.nativeBackgroundColor = themeInfo.background
        terminal.nativeForegroundColor = themeInfo.foreground
        terminal.selectedTextBackgroundColor = NSColor(srgbRed: 0x3b / 255.0, green: 0x55 / 255.0, blue: 0x72 / 255.0, alpha: 0.7)
        terminal.caretColor = themeInfo.cursor
        terminal.installColors(SlateDark.ansiPalette)

        // Prefer common macOS monospace fonts before falling back to the system choice.
        let font = NSFont(name: "SFMono-Regular", size: 13)
            ?? NSFont(name: "Menlo", size: 13)
            ?? NSFont(name: "MesloLGS NF", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.font = font

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Avoid login-shell startup overhead for every attach; tmux already owns the long-lived shell.
        let fullCommand = "export PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:$PATH; cd \(shellEscape(workingDirectory)) && exec \(command)"

        terminal.startProcess(
            executable: shell,
            args: ["-c", fullCommand],
            environment: Self.shellEnvironment()
        )

        return terminal
    }

    public func destroySurface(_ surface: NSView) {
        // LocalProcessTerminalView cleans up on dealloc
    }

    public func surfaceDidResize(_ surface: NSView, to size: NSSize) {
        // SwiftTerm handles resize automatically via NSView layout
    }

    public func focusSurface(_ surface: NSView) {
        surface.window?.makeFirstResponder(surface)
    }

    // MARK: - Private

    private func shellEscape(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        // tmux and many CLI tools expect a color-capable TERM.
        env["TERM"] = "xterm-256color"
        return env.map { "\($0.key)=\($0.value)" }
    }
}

// MARK: - Slate ANSI Palette

@MainActor
private enum SlateDark {
    static func color(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Color {
        Color(red: UInt16(r) << 8, green: UInt16(g) << 8, blue: UInt16(b) << 8)
    }

    // ANSI palette used by the embedded terminal.
    static let ansiPalette: [Color] = [
        // Normal (0-7)
        color(0x18, 0x20, 0x28),  // 0 black
        color(0xff, 0x6f, 0x85),  // 1 red
        color(0x72, 0xd7, 0x9a),  // 2 green
        color(0xf0, 0xd6, 0x79),  // 3 yellow
        color(0x7b, 0xa7, 0xff),  // 4 blue
        color(0xc8, 0xa5, 0xff),  // 5 magenta
        color(0x62, 0xd4, 0xc7),  // 6 cyan
        color(0xe7, 0xed, 0xf5),  // 7 white
        // Bright (8-15)
        color(0x4b, 0x5c, 0x6f),  // 8  bright black
        color(0xff, 0x86, 0x9b),  // 9  bright red
        color(0x8d, 0xe3, 0xab),  // 10 bright green
        color(0xf6, 0xe1, 0x93),  // 11 bright yellow
        color(0x97, 0xbb, 0xff),  // 12 bright blue
        color(0xd6, 0xbc, 0xff),  // 13 bright magenta
        color(0x86, 0xe2, 0xd5),  // 14 bright cyan
        color(0xf1, 0xf6, 0xfd),  // 15 bright white
    ]
}
