import AppKit
import WarrenTerminalRenderer
@preconcurrency import SwiftTerm

/// AppKit values used to configure one remote terminal surface.
@MainActor
public struct SwiftTermTheme {
    public let background: NSColor
    public let foreground: NSColor
    public let cursor: NSColor
    public let selection: NSColor
    public let ansiPalette: [SwiftTerm.Color]

    public init(
        background: NSColor,
        foreground: NSColor,
        cursor: NSColor,
        selection: NSColor,
        ansiPalette: [SwiftTerm.Color]
    ) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.ansiPalette = ansiPalette
    }

    /// Superset's built-in default dark theme, Ember.
    public static let ember = Self(
        background: NSColor(srgbRed: 0x15 / 255, green: 0x11 / 255, blue: 0x10 / 255, alpha: 1),
        foreground: NSColor(srgbRed: 0xea / 255, green: 0xe8 / 255, blue: 0xe6 / 255, alpha: 1),
        cursor: NSColor(srgbRed: 0xe0 / 255, green: 0x78 / 255, blue: 0x50 / 255, alpha: 1),
        selection: NSColor(srgbRed: 0xe0 / 255, green: 0x78 / 255, blue: 0x50 / 255, alpha: 0.25),
        ansiPalette: Self.emberPalette
    )

    @available(*, deprecated, renamed: "ember")
    public static let slate = ember

    private static var emberPalette: [SwiftTerm.Color] {
        TerminalPalette.ember.map {
            SwiftTerm.Color(
                red: UInt16($0.red) * 257,
                green: UInt16($0.green) * 257,
                blue: UInt16($0.blue) * 257
            )
        }
    }
}

/// Font selection stays value-typed so SwiftUI updates do not retain AppKit
/// objects outside the main actor.
public struct SwiftTermFont: Hashable, Sendable {
    private static let supersetFamilies = [
        "JetBrains Mono",
        "JetBrainsMono Nerd Font",
        "MesloLGM Nerd Font",
        "MesloLGM NF",
        "MesloLGS NF",
        "MesloLGS Nerd Font",
        "Hack Nerd Font",
        "FiraCode Nerd Font",
        "CaskaydiaCove Nerd Font",
        "Menlo",
        "Monaco",
        "Courier New",
    ]

    public let family: String?
    public let size: CGFloat

    public init(family: String? = nil, size: CGFloat = 14) {
        self.family = family
        self.size = size.isFinite && size > 0 ? size : 14
    }

    @MainActor
    var nsFont: NSFont {
        if let family, let font = NSFont(name: family, size: size) {
            return font
        }
        for family in Self.supersetFamilies {
            if let font = NSFont(name: family, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public static let systemMono = Self(size: 14)
}
