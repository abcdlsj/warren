import SwiftUI
import AppKit

/// Central design tokens shared across SwiftUI views and AppKit chrome.
public enum DenTokens {

    // MARK: - Ember Night Palette

    public enum Palette {
        public static let crust = SwiftUI.Color(nsColor: nsColor(hex: "#151110"))
        public static let mantle = SwiftUI.Color(nsColor: nsColor(hex: "#1a1716"))
        public static let base = SwiftUI.Color(nsColor: nsColor(hex: "#201e1c"))
        public static let surface0 = SwiftUI.Color(nsColor: nsColor(hex: "#252220"))
        public static let surface1 = SwiftUI.Color(nsColor: nsColor(hex: "#2a2827"))
        public static let surface2 = SwiftUI.Color(nsColor: nsColor(hex: "#3a3837"))
        public static let overlay0 = SwiftUI.Color(nsColor: nsColor(hex: "#a8a5a3"))
        public static let overlay1 = SwiftUI.Color(nsColor: nsColor(hex: "#d0cbc7"))
        public static let text = SwiftUI.Color(nsColor: nsColor(hex: "#eae8e6"))
        public static let subtext1 = SwiftUI.Color(nsColor: nsColor(hex: "#dbd7d3"))
        public static let subtext0 = SwiftUI.Color(nsColor: nsColor(hex: "#a8a5a3"))

        public static let blue = SwiftUI.Color(nsColor: nsColor(hex: "#61afef"))
        public static let green = SwiftUI.Color(nsColor: nsColor(hex: "#7ec699"))
        public static let red = SwiftUI.Color(nsColor: nsColor(hex: "#dc6b6b"))
        public static let peach = SwiftUI.Color(nsColor: nsColor(hex: "#e07850"))
        public static let yellow = SwiftUI.Color(nsColor: nsColor(hex: "#e5c07b"))
        public static let mauve = SwiftUI.Color(nsColor: nsColor(hex: "#c678dd"))
        public static let teal = SwiftUI.Color(nsColor: nsColor(hex: "#56b6c2"))
        public static let pink = SwiftUI.Color(nsColor: nsColor(hex: "#d494e6"))
        public static let rosewater = SwiftUI.Color(nsColor: nsColor(hex: "#f0d0c2"))
        public static let flamingo = SwiftUI.Color(nsColor: nsColor(hex: "#e88888"))
        public static let sky = SwiftUI.Color(nsColor: nsColor(hex: "#7ec0f5"))
        public static let lavender = SwiftUI.Color(nsColor: nsColor(hex: "#9c8cf2"))
    }

    // MARK: - Semantic Colors

    public enum Color {
        public static let panel = Palette.mantle
        public static let panelRaised = Palette.base
        public static let panelMuted = Palette.surface0
        public static let rowHover = Palette.surface0.opacity(0.78)
        public static let rowSelected = Palette.surface0.opacity(0.94)
        public static let rowSelectedStrong = Palette.surface1.opacity(0.96)

        public static let error = Palette.red
        public static let success = Palette.green
        public static let warning = Palette.peach
        public static let attention = Palette.yellow
        public static let info = Palette.sky
        public static let active = Palette.peach
        public static let inactive = Palette.overlay0
        public static let muted = Palette.subtext0
        public static let accent = Palette.peach
        public static let border = Palette.surface1
        public static let borderStrong = Palette.surface2
        public static let pill = Palette.surface1
        public static let toolbarButton = Palette.surface0
        public static let toolbarButtonHover = Palette.surface1
    }

    // MARK: - AppKit Semantic Colors (shared with App chrome)

    public enum Cocoa {
        public static let background = nsColor(hex: "#151110")
        public static let panel = nsColor(hex: "#1a1716")
        public static let panelRaised = nsColor(hex: "#201e1c")
        public static let panelMuted = nsColor(hex: "#252220")
        public static let border = nsColor(hex: "#2a2827")
        public static let text = nsColor(hex: "#eae8e6")
        public static let subtext = nsColor(hex: "#a8a5a3")
        public static let accent = nsColor(hex: "#e07850")
        public static let accentWeak = nsColor(hex: "#e07850").withAlphaComponent(0.18)
    }

    // MARK: - Project Badge Colors

    public enum BadgeColors {
        static let pool: [SwiftUI.Color] = [
            Palette.peach, Palette.green, Palette.yellow, Palette.blue,
            Palette.teal, Palette.mauve, Palette.sky, Palette.flamingo,
        ]

        public static func color(for name: String) -> SwiftUI.Color {
            // Stable hashing gives each project a repeatable accent without storing extra metadata.
            let hash = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            return pool[abs(hash) % pool.count]
        }
    }

    // MARK: - Typography

    public enum Font {
        public static let caption2 = SwiftUI.Font.system(size: 10, weight: .medium)
        public static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        public static let footnote = SwiftUI.Font.system(size: 12, weight: .regular)
        public static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        public static let headline = SwiftUI.Font.system(size: 14, weight: .semibold)
        public static let title3 = SwiftUI.Font.system(size: 16, weight: .semibold)
        public static let title2 = SwiftUI.Font.system(size: 18, weight: .bold)

        public static let code = SwiftUI.Font(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        public static let monoSmall = SwiftUI.Font(NSFont.monospacedSystemFont(ofSize: 10, weight: .regular))

        public static let sectionTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        public static let rowTitle = SwiftUI.Font.system(size: 13, weight: .regular)
        public static let rowTitleBold = SwiftUI.Font.system(size: 13, weight: .semibold)
        public static let windowTitle = SwiftUI.Font.system(size: 12, weight: .medium)
        public static let label = SwiftUI.Font.system(size: 11, weight: .medium)
        public static let badgeCount = SwiftUI.Font.system(size: 9, weight: .bold, design: .rounded)
        public static let badgeLetter = SwiftUI.Font.system(size: 11, weight: .bold, design: .rounded)
        public static let shortcut = SwiftUI.Font(NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold))
    }

    // MARK: - Spacing

    public enum Spacing {
        public static let xxs: CGFloat = 1
        public static let xs: CGFloat = 3
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 20
        public static let emptyState: CGFloat = 40
    }

    // MARK: - Corner Radius

    public enum Radius {
        public static let small: CGFloat = 5
        public static let medium: CGFloat = 9
        public static let large: CGFloat = 14
        public static let badge: CGFloat = 10
    }

    // MARK: - Icon

    public enum Icon {
        public static let sidebarPrimary: CGFloat = 14
        public static let sidebarSecondary: CGFloat = 12
        public static let sidebarAction: CGFloat = 12
        public static let chevron: CGFloat = 9
        public static let dot: CGFloat = 6
        public static let indicator: CGFloat = 7
    }

    // MARK: - Sizes

    public enum Size {
        public static let iconFrame: CGFloat = 18
        public static let swatch: CGFloat = 10
        public static let badgeSize: CGFloat = 22
        public static let activeBar: CGFloat = 3
    }

    // MARK: - Opacity

    public enum Opacity {
        public static let subtle: Double = 0.08
        public static let light: Double = 0.2
        public static let medium: Double = 0.34
    }
}

// MARK: - Shared Icon View

/// Small helper for consistently sized SF Symbols in the sidebar.
public struct SidebarIcon: View {
    let systemName: String
    let color: SwiftUI.Color
    let size: CGFloat

    public init(_ systemName: String, color: SwiftUI.Color, size: CGFloat = DenTokens.Icon.sidebarPrimary) {
        self.systemName = systemName
        self.color = color
        self.size = size
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
            .frame(width: DenTokens.Size.iconFrame, height: DenTokens.Size.iconFrame)
    }
}

// MARK: - Project Badge (colored letter circle)

/// Colored project badge derived from the repository name.
public struct ProjectBadge: View {
    let name: String
    let size: CGFloat

    public init(_ name: String, size: CGFloat = DenTokens.Size.badgeSize) {
        self.name = name
        self.size = size
    }

    private var letter: String {
        String(name.prefix(1)).uppercased()
    }

    private var badgeColor: SwiftUI.Color {
        DenTokens.BadgeColors.color(for: name)
    }

    public var body: some View {
        Text(letter)
            .font(DenTokens.Font.badgeLetter)
            .foregroundStyle(badgeColor)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(badgeColor.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(SwiftUI.Color.white.opacity(0.08), lineWidth: 0.8)
            )
    }
}

// MARK: - Hex Color Helper

/// Shared hex-to-NSColor helper so AppKit and SwiftUI can use the same palette definitions.
public func nsColor(hex: String) -> NSColor {
    let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    let scanner = Scanner(string: h)
    var rgb: UInt64 = 0
    scanner.scanHexInt64(&rgb)

    let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
    let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
    let b = CGFloat(rgb & 0xFF) / 255.0
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
}
