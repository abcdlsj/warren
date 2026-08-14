import SwiftUI
import WarrenDesignSystem
import WarrenDomain

struct WarrenDesktopSettingsView: View {
    let onBack: () -> Void

    @AppStorage(WarrenPreferenceKey.terminalTitleTemplate)
    private var titleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.terminalFontFamily)
    private var fontFamily = TerminalFontPreference.defaultFamily
    @AppStorage(WarrenPreferenceKey.terminalFontSize)
    private var fontSize = TerminalFontPreference.defaultSize
    @Environment(\.colorScheme) private var colorScheme

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case terminalFont = "Terminal font"
        case terminalTitle = "Terminal title"

        var id: String { rawValue }
    }

    @State private var selectedSection: SettingsSection = .terminalFont

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            header(tokens: tokens)

            WarrenDesktopChromeDivider()

            HStack(spacing: 0) {
                navigationPanel(tokens: tokens)
                    .frame(width: 220)

                Rectangle()
                    .fill(tokens.border)
                    .frame(width: WarrenSpacing.hairline)

                detailPanel(tokens: tokens)
            }
        }
        .background(tokens.background)
    }

    private func header(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.standard) {
            Button(action: onBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Warren")
            Text("Settings")
                .font(WarrenTypography.screenTitle)
            Spacer()
        }
        .padding(.leading, WarrenLayoutMetrics.macTrafficLightInset)
        .padding(.trailing, WarrenSpacing.large)
        .frame(height: WarrenLayoutMetrics.tabBarHeight + 16)
        .background(tokens.chromeSurface)
    }

    private func navigationPanel(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            Text("TERMINAL")
                .font(WarrenTypography.sectionLabel)
                .tracking(0.75)
                .foregroundStyle(tokens.mutedForeground)
                .padding(.horizontal, WarrenSpacing.standard)
                .padding(.top, WarrenSpacing.standard)
                .padding(.bottom, WarrenSpacing.xs)

            ForEach(SettingsSection.allCases) { section in
                let isSelected = selectedSection == section
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: WarrenSpacing.small) {
                        Text(section.rawValue)
                            .font(isSelected ? WarrenTypography.navigationGroup : WarrenTypography.navigationItem)
                            .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, WarrenSpacing.standard)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(.rect)
                }
                .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected))
                .accessibilityLabel(section.rawValue)
                .accessibilityValue(isSelected ? "Selected" : "")
                .accessibilityIdentifier("settings.section.\(section.id)")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tokens.sidebarSurface)
    }

    private func detailPanel(tokens: WarrenColorTokens) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                switch selectedSection {
                case .terminalFont:
                    terminalFontSection(tokens: tokens)
                case .terminalTitle:
                    terminalTitleSection(tokens: tokens)
                }

                Button("Restore Terminal Defaults") {
                    titleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
                    fontFamily = TerminalFontPreference.defaultFamily
                    fontSize = TerminalFontPreference.defaultSize
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityIdentifier("settings.restore-defaults")
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.vertical, 42)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .id(selectedSection)
        }
    }

    private func terminalFontSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Terminal font", detail: "Applied to every terminal surface.", tokens: tokens) {
            HStack(alignment: .bottom, spacing: WarrenSpacing.standard) {
                VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                    Text("Font family").font(WarrenTypography.supporting)
                    TextField("monospace", text: $fontFamily)
                        .textFieldStyle(.roundedBorder)
                        .font(WarrenTypography.code)
                }
                VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                    Text("Size").font(WarrenTypography.supporting)
                    Stepper(value: $fontSize, in: 8...32, step: 1) {
                        Text("\(Int(fontSize)) pt")
                            .font(WarrenTypography.code)
                            .frame(width: 44, alignment: .leading)
                    }
                }
                .frame(width: 150)
            }
            Text("Aa  The quick brown fox  0123456789")
                .font(.custom(normalizedFont.family, size: normalizedFont.size))
                .foregroundStyle(tokens.foreground)
                .padding(WarrenSpacing.standard)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tokens.fillHover)
                .clipShape(.rect(cornerRadius: WarrenRadius.row))
        }
    }

    private func terminalTitleSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Terminal title", detail: "Build a title from live Session metadata.", tokens: tokens) {
            TextField("Title template", text: $titleTemplate)
                .textFieldStyle(.roundedBorder)
                .font(WarrenTypography.code)
            Text(preview)
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading) {
                ForEach(TerminalDisplayTitleTemplate.placeholders, id: \.token) { placeholder in
                    Button {
                        if !titleTemplate.isEmpty, !titleTemplate.hasSuffix(" ") { titleTemplate += " " }
                        titleTemplate += placeholder.token
                    } label: {
                        HStack {
                            Text(placeholder.token).font(WarrenTypography.compactCode)
                            Spacer()
                            Text(placeholder.description)
                                .font(WarrenTypography.navigationMeta)
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        .padding(6)
                        .background(tokens.fillHover)
                        .clipShape(.rect(cornerRadius: WarrenRadius.small))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        detail: String,
        tokens: WarrenColorTokens,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                Text(title).font(WarrenTypography.bodyEmphasis)
                Text(detail).font(WarrenTypography.supporting).foregroundStyle(tokens.mutedForeground)
            }
            content()
        }
    }

    private var normalizedFont: TerminalFontPreference {
        TerminalFontPreference(family: fontFamily, size: fontSize)
    }

    private var preview: String {
        "Preview: " + TerminalDisplayTitleTemplate(rawValue: titleTemplate).render(.init(
            session: "Claude", command: "claude", directory: "/Users/me/Workspace/warren",
            workspace: "warren", branch: "main", host: "MacBook Pro", user: "me", os: "macOS"
        ))
    }
}
