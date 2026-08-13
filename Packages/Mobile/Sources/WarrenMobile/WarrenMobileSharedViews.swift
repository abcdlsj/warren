import SwiftUI
import WarrenDesignSystem

struct WarrenMobileSectionHeading: View {
    let title: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(title)
            .font(WarrenTypography.sectionLabel)
            .tracking(1)
            .foregroundStyle(tokens.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WarrenSpacing.standard)
            .padding(.top, WarrenSpacing.medium)
            .padding(.bottom, WarrenSpacing.small)
            .accessibilityAddTraits(.isHeader)
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}

struct WarrenMobileEmptyState: View {
    let title: String
    let message: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            Text(title).font(WarrenTypography.emptyState)
            Text(message)
                .font(WarrenTypography.badge)
                .foregroundStyle(tokens.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WarrenSpacing.standard)
        .padding(.vertical, WarrenSpacing.large)
        .accessibilityElement(children: .combine)
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}

struct WarrenMobileMissingDestinationView: View {
    var body: some View {
        ContentUnavailableView(
            "Unavailable",
            systemImage: "questionmark.folder",
            description: Text("This item is no longer in the local fixture.")
        )
        .navigationTitle("Unavailable")
    }
}
