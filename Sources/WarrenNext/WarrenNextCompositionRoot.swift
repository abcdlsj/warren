import SwiftUI
import UniformTypeIdentifiers
import WarrenDesktop
import WarrenDomain
import GhosttyAdapter
import WarrenApplication
import WarrenStateStore
import WarrenDesignSystem

struct WarrenNextCompositionRoot: View {
    @State private var remoteModel = WarrenRemoteApplicationModel()
    @State private var isProjectImporterPresented = false
    @State private var supersetImportPreview: SupersetImportPreview?
    @State private var isSupersetImporting = false
    @State private var sessionCreatorWorkspaceID: WorkspaceID?
    @State private var workspaceCreatorProjectID: ProjectID?
    @AppStorage(WarrenPreferenceKey.terminalFontFamily)
    private var terminalFontFamily = TerminalFontPreference.defaultFamily
    @AppStorage(WarrenPreferenceKey.terminalFontSize)
    private var terminalFontSize = TerminalFontPreference.defaultSize
    @AppStorage("executionEndpoint")
    private var selectedEndpointID = "local"
    @State private var endpointCatalog: [WarrenRemoteEndpointConfiguration]

    @MainActor
    init() {
        // Endpoint configuration is user input, not frame state. Read it once
        // when the composition root is created instead of touching disk on
        // every SwiftUI body evaluation (terminal output can invalidate the
        // root frequently).
        _endpointCatalog = State(initialValue: WarrenEndpointCatalog.load().endpoints)
    }

    var body: some View {
        WarrenDesktopRoot(
            projection: activeProjection,
            navigation: activeNavigation,
            chromeMode: .workspace,
            actions: WarrenDesktopActions(send: handle),
            webRelayStatus: remoteModel.webRelayStatus,
            endpointOptions: endpointOptions,
            selectedEndpointID: selectedEndpointID,
            onSelectEndpoint: selectEndpoint,
            onWebRelayStart: { remoteModel.startWebRelayFromUI() },
            onWebRelayStop: { remoteModel.stopWebRelay() },
            onWebRelayOpenURL: { remoteModel.openWebRelayURL($0) },
            onWebRelayCopyURL: { remoteModel.copyWebRelayURL($0) }
        ) { context in
            WarrenNextTerminalSurfaceView(
                context: context,
                surfaces: remoteModel.mountedSurfaces
            )
        }
        .preferredColorScheme(.dark)
        .disabled(isSupersetImporting)
        .overlay {
            if isSupersetImporting {
                ZStack {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                    VStack(spacing: WarrenSpacing.compact) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading Superset…")
                            .font(WarrenTypography.navigationItem)
                            .foregroundStyle(.primary)
                        Text("Reading workspaces project by project, please wait")
                            .font(WarrenTypography.supporting)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, WarrenSpacing.large)
                    .padding(.vertical, WarrenSpacing.medium)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .transition(.opacity)
            }
        }
        .fileImporter(
            isPresented: $isProjectImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: importProject
        )
        .fileDialogMessage("Choose a local folder as the project.")
        .fileDialogConfirmationLabel("Add Project")
        .sheet(item: $supersetImportPreview) { preview in
            WarrenNextSupersetImportView(preview: preview) {
                supersetImportPreview = nil
                isSupersetImporting = true
                Task {
                    await remoteModel.commitSupersetImport(preview)
                    isSupersetImporting = false
                }
            }
        }
        .sheet(isPresented: sessionCreatorBinding) {
            if let workspaceID = sessionCreatorWorkspaceID {
                WarrenNextSessionCreatorView(
                    workspaceName: activeProjection.workspace(id: workspaceID)?.name ?? "Workspace"
                ) { request in
                    remoteModel.createSession(workspaceID: workspaceID, request: request)
                }
            }
        }
        .sheet(isPresented: workspaceCreatorBinding) {
            if let projectID = workspaceCreatorProjectID,
               let project = activeProjection.projectGroup(id: projectID)?.project {
                WarrenNextWorkspaceCreatorView(project: project) { request in
                    remoteModel.createWorkspace(projectID: projectID, request: request)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WebRelayCommand.copyLocalURL)) { _ in
            remoteModel.copyLocalWebURL()
        }
        .onChange(of: terminalFontFamily) { _, _ in updateTerminalFont() }
        .onChange(of: terminalFontSize) { _, _ in updateTerminalFont() }
        .onReceive(NotificationCenter.default.publisher(for: WebRelayCommand.startCloudflare)) { _ in
            remoteModel.startCloudflareWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebRelayCommand.stopCloudflare)) { _ in
            remoteModel.stopCloudflareWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebRelayCommand.startTailscale)) { _ in
            remoteModel.startTailscaleWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebRelayCommand.stopTailscale)) { _ in
            remoteModel.stopTailscaleWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebRelayCommand.copySecureURL)) { _ in
            remoteModel.copySecureWebURL()
        }
        .task { restoreEndpointSelection() }
        .onChange(of: selectedEndpointID) { _, _ in connectSelectedEndpoint() }
    }

    private func updateTerminalFont() {
        remoteModel.updateTerminalFont(TerminalFontPreference(
            family: terminalFontFamily,
            size: terminalFontSize
        ))
    }

    private func handle(_ action: WarrenDesktopAction) {
        if action == .addProject {
            if isLocalEndpoint {
                isProjectImporterPresented = true
            } else {
                remoteModel.report(NSError(domain: "WarrenRemote", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Remote projects must use remote paths; add them from the remote CLI.",
                ]))
            }
        } else if action == .importSuperset {
            if isLocalEndpoint {
                beginSupersetImport()
            } else {
                remoteModel.report(NSError(domain: "WarrenRemote", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Superset import must run on the machine hosting the daemon.",
                ]))
            }
        } else if case .requestNewWorkspace(let projectID) = action {
            workspaceCreatorProjectID = projectID
        } else if case .requestNewSession(let workspaceID) = action {
            sessionCreatorWorkspaceID = workspaceID
        } else {
            remoteModel.perform(action)
        }
    }

    private var endpointOptions: [WarrenDesktopEndpointOption] {
        [.init(id: "local", label: "Local", isLocal: true)] + endpointCatalog.map {
            .init(id: $0.id, label: $0.name)
        }
    }

    private var isLocalEndpoint: Bool { selectedEndpointID == "local" }
    private var activeProjection: WarrenDesktopProjection {
        remoteModel.projection
    }
    private var activeNavigation: WarrenDesktopNavigationState {
        remoteModel.navigation
    }

    private func selectEndpoint(_ id: String) {
        guard endpointOptions.contains(where: { $0.id == id }) else { return }
        selectedEndpointID = id
    }

    private func restoreEndpointSelection() {
        guard endpointOptions.contains(where: { $0.id == selectedEndpointID }) else {
            selectedEndpointID = "local"
            return
        }
        connectSelectedEndpoint()
    }

    private func connectSelectedEndpoint() {
        guard isLocalEndpoint else {
            guard let endpoint = endpointCatalog.first(where: { $0.id == selectedEndpointID }) else {
                remoteModel.disconnect()
                return
            }
            remoteModel.connect(endpoint)
            return
        }
        remoteModel.disconnect()
        Task { @MainActor in
            for _ in 0..<30 {
                let endpoint = WarrenRemoteEndpointConfiguration.localDaemon()
                if !endpoint.token.isEmpty, await isLocalDaemonReady(endpoint) {
                    remoteModel.connect(endpoint)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            remoteModel.report(NSError(domain: "WarrenRemote", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "The local daemon is not running; check the Warren status in the menu bar.",
            ]))
        }
    }

    private func isLocalDaemonReady(_ endpoint: WarrenRemoteEndpointConfiguration) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8789/v1/state") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.4
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func beginSupersetImport() {
        guard !isSupersetImporting else { return }
        isSupersetImporting = true
        Task {
            do {
                supersetImportPreview = try await remoteModel.previewSupersetImport()
            } catch {
                remoteModel.report(error)
            }
            isSupersetImporting = false
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
                await remoteModel.addProject(folder)
            }
        case .failure(let error):
            remoteModel.report(error)
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
    let surfaces: [GhosttySurface]
    @State private var focusDriver = GhosttyFocusDriver()

    var body: some View {
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
