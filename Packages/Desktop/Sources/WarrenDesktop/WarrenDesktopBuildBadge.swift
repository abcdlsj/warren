import SwiftUI
import WarrenDesignSystem

/// Build provenance read from the app bundle. `scripts/build-app.sh` stamps
/// `build-variant.txt` (`build` for debug previews, `release` for release
/// builds); `WARREN_BUILD_VARIANT` covers `swift run` sessions.
enum WarrenBuildVariant {
    static let isBuild: Bool = {
        if let url = Bundle.main.url(forResource: "build-variant", withExtension: "txt"),
           let value = try? String(contentsOf: url, encoding: .utf8) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines) == "build"
        }
        return ProcessInfo.processInfo.environment["WARREN_BUILD_VARIANT"] == "build"
    }()
}

/// Small top-of-window marker that tells preview builds apart from release
/// installs when several Warren windows are open side by side.
struct WarrenDesktopBuildBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Text("BUILD")
            .font(WarrenTypography.sectionLabel)
            .tracking(1.0)
            .foregroundStyle(tokens.amber)
            .accessibilityLabel("Build version")
            .help("This window is a locally built preview")
    }
}
