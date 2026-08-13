import SwiftUI
import UniformTypeIdentifiers
import WarrenDesktop
import WarrenDomain
import GhosttyAdapter
import WarrenApplication
import WarrenStateStore

struct WarrenNextCompositionRoot: View {
    @State private var model: WarrenNextApplicationModel
    @State private var isProjectImporterPresented = false
    @State private var isSupersetDatabaseImporterPresented = false
    @State private var supersetImportPreview: SupersetImportPreview?
    @State private var sessionCreatorWorkspaceID: WorkspaceID?
    @State private var workspaceCreatorProjectID: ProjectID?

    @MainActor
    init(model: WarrenNextApplicationModel = .live()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        WarrenDesktopRoot(
            projection: model.desktopProjection,
            navigation: model.navigation,
            chromeMode: .workspace,
            actions: WarrenDesktopActions(send: handle)
        ) { context in
            WarrenNextTerminalSurfaceView(
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
        .fileImporter(
            isPresented: $isSupersetDatabaseImporterPresented,
            allowedContentTypes: [.database, .data],
            allowsMultipleSelection: false,
            onCompletion: selectSupersetDatabase
        )
        .fileDialogMessage("Choose Superset local.db.")
        .fileDialogConfirmationLabel("Preview Import")
        .sheet(item: $supersetImportPreview) { preview in
            WarrenNextSupersetImportView(preview: preview) {
                supersetImportPreview = nil
                Task { await model.commitSupersetImport(preview) }
            }
        }
        .sheet(isPresented: sessionCreatorBinding) {
            if let workspaceID = sessionCreatorWorkspaceID {
                WarrenNextSessionCreatorView(
                    workspaceName: model.desktopProjection.workspace(id: workspaceID)?.name ?? "Workspace"
                ) { request in
                    model.createSession(workspaceID: workspaceID, request: request)
                }
            }
        }
        .sheet(isPresented: workspaceCreatorBinding) {
            if let projectID = workspaceCreatorProjectID,
               let project = model.desktopProjection.projectGroup(id: projectID)?.project {
                WarrenNextWorkspaceCreatorView(project: project) { request in
                    model.createWorkspace(projectID: projectID, request: request)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WebRelayCommand.copyLocalURL)) { _ in
            model.copyLocalWebURL()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebRelayCommand.startCloudflare)) { _ in
            model.startCloudflareWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebRelayCommand.stopCloudflare)) { _ in
            model.stopCloudflareWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebRelayCommand.startTailscale)) { _ in
            model.startTailscaleWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebRelayCommand.stopTailscale)) { _ in
            model.stopTailscaleWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebRelayCommand.copySecureURL)) { _ in
            model.copySecureWebURL()
        }
    }

    private func handle(_ action: WarrenDesktopAction) {
        if action == .addProject {
            isProjectImporterPresented = true
        } else if action == .importSuperset {
            beginSupersetImport()
        } else if case .requestNewWorkspace(let projectID) = action {
            workspaceCreatorProjectID = projectID
        } else if case .requestNewSession(let workspaceID) = action {
            sessionCreatorWorkspaceID = workspaceID
        } else {
            model.perform(action)
        }
    }

    private func beginSupersetImport() {
        let defaultURL = WarrenApplicationDefaults.supersetDatabaseURL()
        if FileManager.default.fileExists(atPath: defaultURL.path) {
            previewSupersetImport(defaultURL)
        } else {
            isSupersetDatabaseImporterPresented = true
        }
    }

    private func selectSupersetDatabase(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let databaseURL = urls.first else { return }
            previewSupersetImport(databaseURL)
        case .failure(let error):
            model.report(error)
        }
    }

    private func previewSupersetImport(_ databaseURL: URL) {
        Task {
            let hasScopedAccess = databaseURL.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess { databaseURL.stopAccessingSecurityScopedResource() }
            }
            do {
                supersetImportPreview = try await model.previewSupersetImport(from: databaseURL)
            } catch {
                model.report(error)
            }
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

    private var workspaceCreatorBinding: Binding<Bool> {
        Binding(
            get: { workspaceCreatorProjectID != nil },
            set: { isPresented in
                if !isPresented { workspaceCreatorProjectID = nil }
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

private struct WarrenNextSupersetImportView: View {
    let preview: SupersetImportPreview
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var allWorkspaces: [SupersetImportWorkspaceCandidate] {
        preview.projects.flatMap(\.workspaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Superset")
                .font(.title2.weight(.semibold))
            Text("This is a one-time copy. Warren will not modify or synchronize Superset.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                summaryRow("Ready projects", preview.projects.filter { $0.status == .ready }.count)
                summaryRow("Ready workspaces", allWorkspaces.filter { $0.status == .ready }.count)
                summaryRow("Missing paths", allWorkspaces.filter { $0.status == .missing }.count)
                summaryRow("Invalid Git paths", allWorkspaces.filter { $0.status == .invalid }.count)
            }

            List(preview.projects) { project in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(project.name).font(.body.weight(.medium))
                        Spacer()
                        Text(project.status.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(project.status == .ready ? .green : .secondary)
                    }
                    Text(project.repositoryPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let diagnostic = project.diagnostic {
                        Text(diagnostic).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 180)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") {
                    dismiss()
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(preview.readyProjectCount == 0)
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 560, maxWidth: 560, minHeight: 380)
    }

    private func summaryRow(_ title: String, _ value: Int) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text("\(value)").fontWeight(.medium)
        }
    }
}

private struct WarrenNextTerminalSurfaceView: View {
    let context: WarrenDesktopTerminalContext
    let model: WarrenNextApplicationModel
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
