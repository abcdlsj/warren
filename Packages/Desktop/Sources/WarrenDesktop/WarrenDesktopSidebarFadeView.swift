import SwiftUI

/// Kept as a source-compatible placeholder while all callers use
/// `WarrenOverflowFadeScrollView`, which owns conditional edge visibility.
@available(*, deprecated, message: "Use WarrenOverflowFadeScrollView")
struct WarrenDesktopSidebarFade: View {
    enum Edge { case top, bottom }
    let edge: Edge

    var body: some View { EmptyView() }
}
