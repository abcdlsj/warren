/// A platform-neutral RGB color used by the terminal's sixteen ANSI slots.
public struct TerminalPaletteColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Superset's default Ember terminal palette.
public enum TerminalPalette {
    public static let ember: [TerminalPaletteColor] = [
        color(0x15, 0x11, 0x10), color(0xdc, 0x6b, 0x6b),
        color(0x7e, 0xc6, 0x99), color(0xe5, 0xc0, 0x7b),
        color(0x61, 0xaf, 0xef), color(0xc6, 0x78, 0xdd),
        color(0x56, 0xb6, 0xc2), color(0xea, 0xe8, 0xe6),
        color(0x5c, 0x58, 0x56), color(0xe8, 0x88, 0x88),
        color(0x98, 0xd1, 0xa8), color(0xec, 0xd0, 0x8f),
        color(0x7e, 0xc0, 0xf5), color(0xd4, 0x94, 0xe6),
        color(0x73, 0xc7, 0xd3), color(0xff, 0xff, 0xff),
    ]

    @available(*, deprecated, renamed: "ember")
    public static let slate = ember

    private static func color(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> TerminalPaletteColor {
        TerminalPaletteColor(red: red, green: green, blue: blue)
    }
}
