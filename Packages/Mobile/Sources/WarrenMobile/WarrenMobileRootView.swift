import SwiftUI
import WarrenDesignSystem

/// iPhone-first Host → Workspace → Session → terminal shell.
/// Desktop sidebar, tabs and panes are intentionally not reproduced here.
public struct WarrenMobileRootView: View {
    public let fixture: WarrenMobileFixture

    private let onEvent: (WarrenMobileEvent) -> Void
    @State private var path: [WarrenMobileRoute]
    @Environment(\.colorScheme) private var colorScheme

    public init(
        fixture: WarrenMobileFixture = .preview,
        initialPath: [WarrenMobileRoute] = [],
        onEvent: @escaping (WarrenMobileEvent) -> Void = { _ in }
    ) {
        self.fixture = fixture
        self.onEvent = onEvent
        _path = State(initialValue: initialPath)
    }

    public var body: some View {
        NavigationStack(path: $path) {
            WarrenMobileHostListView(fixture: fixture)
                .navigationTitle("Hosts")
                .navigationDestination(for: WarrenMobileRoute.self) { route in
                    destination(for: route)
                }
        }
        .background(tokens.background)
        .foregroundStyle(tokens.foreground)
        .tint(tokens.primary)
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }

    @ViewBuilder
    private func destination(for route: WarrenMobileRoute) -> some View {
        switch route {
        case .host(let hostID):
            if let host = fixture.host(for: hostID) {
                WarrenMobileHostDetailView(host: host, fixture: fixture)
            } else {
                WarrenMobileMissingDestinationView()
            }
        case .workspace(let workspaceID):
            if let workspace = fixture.workspace(for: workspaceID) {
                WarrenMobileWorkspaceDetailView(workspace: workspace, fixture: fixture)
            } else {
                WarrenMobileMissingDestinationView()
            }
        case .session(let sessionID):
            if let session = fixture.session(for: sessionID) {
                WarrenMobileTerminalView(session: session, onEvent: onEvent)
            } else {
                WarrenMobileMissingDestinationView()
            }
        }
    }
}
