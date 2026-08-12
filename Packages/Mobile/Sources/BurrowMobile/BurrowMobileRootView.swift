import SwiftUI
import BurrowDesignSystem

/// iPhone-first Host → Workspace → Session → terminal shell.
/// Desktop sidebar, tabs and panes are intentionally not reproduced here.
public struct BurrowMobileRootView: View {
    public let fixture: BurrowMobileFixture

    private let onEvent: (BurrowMobileEvent) -> Void
    @State private var path: [BurrowMobileRoute]
    @Environment(\.colorScheme) private var colorScheme

    public init(
        fixture: BurrowMobileFixture = .preview,
        initialPath: [BurrowMobileRoute] = [],
        onEvent: @escaping (BurrowMobileEvent) -> Void = { _ in }
    ) {
        self.fixture = fixture
        self.onEvent = onEvent
        _path = State(initialValue: initialPath)
    }

    public var body: some View {
        NavigationStack(path: $path) {
            BurrowMobileHostListView(fixture: fixture)
                .navigationTitle("Hosts")
                .navigationDestination(for: BurrowMobileRoute.self) { route in
                    destination(for: route)
                }
        }
        .background(tokens.background)
        .foregroundStyle(tokens.foreground)
        .tint(tokens.primary)
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }

    @ViewBuilder
    private func destination(for route: BurrowMobileRoute) -> some View {
        switch route {
        case .host(let hostID):
            if let host = fixture.host(for: hostID) {
                BurrowMobileHostDetailView(host: host, fixture: fixture)
            } else {
                BurrowMobileMissingDestinationView()
            }
        case .workspace(let workspaceID):
            if let workspace = fixture.workspace(for: workspaceID) {
                BurrowMobileWorkspaceDetailView(workspace: workspace, fixture: fixture)
            } else {
                BurrowMobileMissingDestinationView()
            }
        case .session(let sessionID):
            if let session = fixture.session(for: sessionID) {
                BurrowMobileTerminalView(session: session, onEvent: onEvent)
            } else {
                BurrowMobileMissingDestinationView()
            }
        }
    }
}
