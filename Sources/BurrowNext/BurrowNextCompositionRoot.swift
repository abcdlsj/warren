import SwiftUI
import UniformTypeIdentifiers
import BurrowDesktop
import BurrowDomain
import GhosttyAdapter

struct BurrowNextCompositionRoot: View {
    @State private var model: BurrowNextApplicationModel
    @State private var isProjectImporterPresented = false
    @State private var sessionCreatorWorkspaceID: WorkspaceID?

    @MainActor
    init(model: BurrowNextApplicationModel = .live()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        BurrowDesktopRoot(
            projection: model.desktopProjection,
            navigation: model.navigation,
            chromeMode: .workspace,
            actions: BurrowDesktopActions(send: handle)
        ) { context in
            BurrowNextTerminalSurfaceView(
                context: context,
                model: model
            )
        }
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $isProjectImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: importProject
        )
        .fileDialogMessage("Choose a local folder as the project.")
        .fileDialogConfirmationLabel("Add Project")
        .sheet(isPresented: sessionCreatorBinding) {
            if let workspaceID = sessionCreatorWorkspaceID {
                BurrowNextSessionCreatorView(
                    workspaceName: model.desktopProjection.workspace(id: workspaceID)?.name ?? "Workspace"
                ) { request in
                    model.createSession(workspaceID: workspaceID, request: request)
                }
            }
        }
    }

    private func handle(_ action: BurrowDesktopAction) {
        if action == .addProject {
            isProjectImporterPresented = true
        } else if case .requestNewSession(let workspaceID) = action {
            // Project/workspace plus buttons carry an explicit destination.
            // Select it before presenting the launcher so the visible tab
            // strip and the eventual Session share one workspace owner.
            model.perform(.selectWorkspace(workspaceID))
            sessionCreatorWorkspaceID = workspaceID
        } else {
            model.perform(action)
        }
    }

    private var sessionCreatorBinding: Binding<Bool> {
        Binding(
            get: { sessionCreatorWorkspaceID != nil },
            set: { isPresented in
                if !isPresented { sessionCreatorWorkspaceID = nil }
            }
        )
    }

    private func importProject(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let folder = urls.first else { return }
            Task {
                let hasScopedAccess = folder.startAccessingSecurityScopedResource()
                defer {
                    if hasScopedAccess { folder.stopAccessingSecurityScopedResource() }
                }
                await model.addProject(folder)
            }
        case .failure(let error):
            model.report(error)
        }
    }
}

private struct BurrowNextTerminalSurfaceView: View {
    let context: BurrowDesktopTerminalContext
    let model: BurrowNextApplicationModel
    @State private var focusDriver = GhosttyFocusDriver()

    var body: some View {
        let surfaces = model.mountedSurfaces

        if surfaces.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting \(context.tab.title)…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                ZStack {
                    ForEach(surfaces) { surface in
                        let isActive = surface.id == context.tab.sessionID
                        GhosttyManagedSurface(
                            surface: surface,
                            isActive: isActive,
                            focusDriver: focusDriver,
                            viewportSize: proxy.size
                        )
                            // Every mounted renderer owns the same pane-sized
                            // viewport, including hidden siblings. Otherwise
                            // AppKit reports the hidden view's 50x17 intrinsic
                            // grid to tmux and switching tabs visibly reflows
                            // the agent before it expands again.
                            .frame(
                                width: proxy.size.width,
                                height: proxy.size.height
                            )
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                            .accessibilityHidden(!isActive)
                    }
                }
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}
