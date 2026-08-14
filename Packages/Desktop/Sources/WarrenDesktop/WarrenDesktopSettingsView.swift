import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// Settings mirror Superset's route layout: a slim window-chrome row on top,
/// a 224pt sidebar with Back/title/search/grouped navigation on the left, and
/// a page-headed detail column (`max-w-5xl`) on the right.
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

        var iconName: String {
            switch self {
            case .terminalFont: "terminal"
            case .terminalTitle: "textformat"
            }
        }

        var detail: String {
            switch self {
            case .terminalFont: "Applied to every terminal surface."
            case .terminalTitle: "Build a title from live Session metadata."
            }
        }

        var searchTerms: [String] {
            switch self {
            case .terminalFont: [rawValue, detail, "font", "family", "size", "typography"]
            case .terminalTitle: [rawValue, detail, "title", "template", "placeholder", "preview"]
            }
        }
    }

    @State private var selectedSection: SettingsSection = .terminalFont
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool

    private var visibleSections: [SettingsSection] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { section in
            section.searchTerms.contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            chromeRow(tokens: tokens)

            WarrenDesktopChromeDivider()

            HStack(spacing: 0) {
                navigationPanel(tokens: tokens)
                    .frame(width: WarrenLayoutMetrics.settingsNavigationWidth)

                Rectangle()
                    .fill(tokens.border)
                    .frame(width: WarrenSpacing.hairline)

                detailPanel(tokens: tokens)
            }
        }
        .background(tokens.background)
        .onExitCommand(perform: onBack)
        .onChange(of: searchQuery) { _, _ in
            if !visibleSections.contains(selectedSection), let first = visibleSections.first {
                selectedSection = first
            }
        }
    }

    private func chromeRow(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: 0) {
            WarrenDesktopTrafficLights()
                .frame(width: WarrenLayoutMetrics.macTrafficLightInset, alignment: .leading)

            WarrenDesktopWindowDragRegion()
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
        .frame(height: WarrenLayoutMetrics.tabBarHeight)
        .background(tokens.chromeSurface)
    }

    private func navigationPanel(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: WarrenSpacing.small) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 12, weight: .medium))
                    Text("Back")
                }
                .font(WarrenTypography.navigationItem)
                .padding(.horizontal, WarrenSpacing.compact)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(WarrenInteractiveRowStyle())
            .padding(.horizontal, WarrenSpacing.xs)
            .accessibilityLabel("Back to Warren")

            Text("Settings")
                .font(WarrenTypography.screenTitle)
                .padding(.horizontal, WarrenSpacing.standard)
                .padding(.top, WarrenSpacing.medium)
                .padding(.bottom, WarrenSpacing.medium)

            searchField(tokens: tokens)
                .padding(.horizontal, WarrenSpacing.xs)
                .padding(.bottom, WarrenSpacing.medium)

            ScrollView {
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    Text("TERMINAL")
                        .font(WarrenTypography.sectionLabel)
                        .tracking(0.75)
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.horizontal, WarrenSpacing.standard)
                        .padding(.top, WarrenSpacing.standard)
                        .padding(.bottom, WarrenSpacing.xs)

                    ForEach(visibleSections) { section in
                        navigationItem(section, tokens: tokens)
                    }

                    if visibleSections.isEmpty {
                        Text("No settings found")
                            .font(WarrenTypography.body)
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, WarrenSpacing.large)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tokens.sidebarSurface)
    }

    private func searchField(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 16)
                .accessibilityHidden(true)

            TextField("Search settings…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(WarrenTypography.navigationItem)
                .focused($searchFocused)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityLabel("Clear settings search")
            }
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .frame(height: WarrenLayoutMetrics.settingsSearchHeight)
        .background(tokens.muted.opacity(0.45))
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .overlay {
            RoundedRectangle(cornerRadius: WarrenRadius.row)
                .stroke(searchFocused ? tokens.ring : .clear, lineWidth: WarrenSpacing.hairline)
        }
    }

    private func navigationItem(
        _ section: SettingsSection,
        tokens: WarrenColorTokens
    ) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: WarrenSpacing.small) {
                Image(systemName: section.iconName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .accessibilityHidden(true)

                Text(section.rawValue)
                    .font(isSelected ? WarrenTypography.navigationGroup : WarrenTypography.navigationItem)
                    .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenSpacing.standard)
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected))
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("settings.section.\(section.id)")
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
            .frame(maxWidth: WarrenLayoutMetrics.settingsContentMaxWidth, alignment: .leading)
            .padding(.horizontal, WarrenSpacing.large)
            .padding(.vertical, WarrenSpacing.large)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .id(selectedSection)
        }
    }

    private func terminalFontSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Terminal font", section: .terminalFont, tokens: tokens) {
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
        settingsSection("Terminal title", section: .terminalTitle, tokens: tokens) {
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
        section: SettingsSection,
        tokens: WarrenColorTokens,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                Text(title).font(WarrenTypography.pageTitle)
                Text(section.detail)
                    .font(WarrenTypography.body)
                    .foregroundStyle(tokens.mutedForeground)
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
