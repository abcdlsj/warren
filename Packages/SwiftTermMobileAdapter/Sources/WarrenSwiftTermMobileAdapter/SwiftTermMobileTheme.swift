#if os(iOS)
import UIKit
import WarrenTerminalRenderer
@preconcurrency import SwiftTerm

/// UIKit values used by one remote terminal surface.
@MainActor
public struct SwiftTermMobileTheme {
    public let background: UIColor
    public let foreground: UIColor
    public let cursor: UIColor
    public let selection: UIColor
    public let ansiPalette: [SwiftTerm.Color]

    public init(
        background: UIColor,
        foreground: UIColor,
        cursor: UIColor,
        selection: UIColor,
        ansiPalette: [SwiftTerm.Color]
    ) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.ansiPalette = ansiPalette
    }

    public static let slate = Self(
        background: UIColor(red: 0x15 / 255, green: 0x11 / 255, blue: 0x10 / 255, alpha: 1),
        foreground: UIColor(red: 0xea / 255, green: 0xe8 / 255, blue: 0xe6 / 255, alpha: 1),
        cursor: UIColor(red: 0x7e / 255, green: 0xca / 255, blue: 0xff / 255, alpha: 1),
        selection: UIColor(red: 0x3b / 255, green: 0x55 / 255, blue: 0x72 / 255, alpha: 0.7),
        ansiPalette: Self.defaultPalette
    )

    private static var defaultPalette: [SwiftTerm.Color] {
        TerminalPalette.slate.map {
            SwiftTerm.Color(
                red: UInt16($0.red) * 257,
                green: UInt16($0.green) * 257,
                blue: UInt16($0.blue) * 257
            )
        }
    }
}

/// Font selection is value-typed so SwiftUI updates do not retain UIKit
/// objects outside the main actor.
public struct SwiftTermMobileFont: Hashable, Sendable {
    public let family: String?
    public let size: CGFloat

    public init(family: String? = nil, size: CGFloat = 13) {
        self.family = family
        self.size = size.isFinite && size > 0 ? size : 13
    }

    @MainActor
    var uiFont: UIFont {
        if let family, let font = UIFont(name: family, size: size) {
            return font
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public static let systemMono = Self(size: 13)
}
#endif
