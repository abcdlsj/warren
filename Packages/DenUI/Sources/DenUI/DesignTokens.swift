import SwiftUI
import AppKit

public enum DenTokens {

    // MARK: - Catppuccin Mocha Palette

    public enum Palette {
        public static let crust = SwiftUI.Color(nsColor: nsColor(hex: "#11111b"))
        public static let mantle = SwiftUI.Color(nsColor: nsColor(hex: "#181825"))
        public static let base = SwiftUI.Color(nsColor: nsColor(hex: "#1e1e2e"))
        public static let surface0 = SwiftUI.Color(nsColor: nsColor(hex: "#313244"))
        public static let surface1 = SwiftUI.Color(nsColor: nsColor(hex: "#45475a"))
        public static let surface2 = SwiftUI.Color(nsColor: nsColor(hex: "#585b70"))
        public static let overlay0 = SwiftUI.Color(nsColor: nsColor(hex: "#6c7086"))
        public static let overlay1 = SwiftUI.Color(nsColor: nsColor(hex: "#7f849c"))
        public static let text = SwiftUI.Color(nsColor: nsColor(hex: "#cdd6f4"))
        public static let subtext1 = SwiftUI.Color(nsColor: nsColor(hex: "#bac2de"))
        public static let subtext0 = SwiftUI.Color(nsColor: nsColor(hex: "#a6adc8"))

        public static let blue = SwiftUI.Color(nsColor: nsColor(hex: "#89b4fa"))
        public static let green = SwiftUI.Color(nsColor: nsColor(hex: "#a6e3a1"))
        public static let red = SwiftUI.Color(nsColor: nsColor(hex: "#f38ba8"))
        public static let peach = SwiftUI.Color(nsColor: nsColor(hex: "#fab387"))
        public static let yellow = SwiftUI.Color(nsColor: nsColor(hex: "#f9e2af"))
        public static let mauve = SwiftUI.Color(nsColor: nsColor(hex: "#cba6f7"))
        public static let teal = SwiftUI.Color(nsColor: nsColor(hex: "#94e2d5"))
        public static let pink = SwiftUI.Color(nsColor: nsColor(hex: "#f5c2e7"))
        public static let rosewater = SwiftUI.Color(nsColor: nsColor(hex: "#f5e0dc"))
        public static let flamingo = SwiftUI.Color(nsColor: nsColor(hex: "#f2cdcd"))
        public static let sky = SwiftUI.Color(nsColor: nsColor(hex: "#89dceb"))
        public static let lavender = SwiftUI.Color(nsColor: nsColor(hex: "#b4befe"))
    }

    // MARK: - Semantic Colors

    public enum Color {
        public static let error = Palette.red
        public static let success = Palette.green
        public static let warning = Palette.peach
        public static let attention = Palette.yellow
        public static let info = Palette.blue
        public static let active = Palette.blue
        public static let inactive = Palette.overlay0
        public static let muted = Palette.subtext0
    }

    // MARK: - Typography

    public enum Font {
        public static let caption2 = SwiftUI.Font.system(size: 10)
        public static let caption = SwiftUI.Font.system(size: 11)
        public static let footnote = SwiftUI.Font.system(size: 12)
        public static let body = SwiftUI.Font.system(size: 13)
        public static let headline = SwiftUI.Font.system(size: 14, weight: .semibold)
        public static let title3 = SwiftUI.Font.system(size: 16, weight: .semibold)
        public static let title2 = SwiftUI.Font.system(size: 18, weight: .bold)

        public static let code = SwiftUI.Font.system(size: 12, design: .monospaced)
        public static let monoSmall = SwiftUI.Font.system(size: 10, design: .monospaced)
        public static let sectionTitle = SwiftUI.Font.system(size: 11, weight: .semibold)
        public static let rowTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        public static let windowTitle = SwiftUI.Font.system(size: 12)
        public static let label = SwiftUI.Font.system(size: 11)
        public static let badgeCount = SwiftUI.Font.system(size: 9, weight: .bold, design: .rounded)
        public static let arrowIcon = SwiftUI.Font.system(size: 8)
        public static let shortcut = SwiftUI.Font.system(size: 10, weight: .medium, design: .monospaced)
    }

    // MARK: - Spacing

    public enum Spacing {
        public static let xxs: CGFloat = 1
        public static let xs: CGFloat = 2
        public static let sm: CGFloat = 4
        public static let md: CGFloat = 6
        public static let lg: CGFloat = 8
        public static let xl: CGFloat = 12
        public static let xxl: CGFloat = 16
        public static let emptyState: CGFloat = 40
    }

    // MARK: - Corner Radius

    public enum Radius {
        public static let small: CGFloat = 4
        public static let medium: CGFloat = 6
        public static let large: CGFloat = 8
    }

    // MARK: - Icon Sizes

    public enum Icon {
        public static let badge: CGFloat = 10
        public static let indicator: CGFloat = 8
        public static let dot: CGFloat = 6
    }

    // MARK: - Sizes

    public enum Size {
        public static let avatar: CGFloat = 36
        public static let avatarFont: CGFloat = 16
        public static let swatch: CGFloat = 10
    }

    // MARK: - Opacity

    public enum Opacity {
        public static let subtle: Double = 0.08
        public static let light: Double = 0.15
        public static let medium: Double = 0.25
    }
}

// MARK: - Hex Color Helper

func nsColor(hex: String) -> NSColor {
    let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    let scanner = Scanner(string: h)
    var rgb: UInt64 = 0
    scanner.scanHexInt64(&rgb)

    let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
    let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
    let b = CGFloat(rgb & 0xFF) / 255.0
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
}
