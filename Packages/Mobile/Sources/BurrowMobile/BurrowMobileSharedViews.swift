import SwiftUI
import BurrowDesignSystem

struct BurrowMobileSectionHeading: View {
    let title: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(title)
            .font(BurrowTypography.sectionLabel)
            .tracking(1)
            .foregroundStyle(tokens.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BurrowSpacing.standard)
            .padding(.top, BurrowSpacing.medium)
            .padding(.bottom, BurrowSpacing.small)
            .accessibilityAddTraits(.isHeader)
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}

struct BurrowMobileEmptyState: View {
    let title: String
    let message: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: BurrowSpacing.xs) {
            Text(title).font(BurrowTypography.emptyState)
            Text(message)
                .font(BurrowTypography.badge)
                .foregroundStyle(tokens.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BurrowSpacing.standard)
        .padding(.vertical, BurrowSpacing.large)
        .accessibilityElement(children: .combine)
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}

struct BurrowMobileMissingDestinationView: View {
    var body: some View {
        ContentUnavailableView(
            "Unavailable",
            systemImage: "questionmark.folder",
            description: Text("This item is no longer in the local fixture.")
        )
        .navigationTitle("Unavailable")
    }
}
