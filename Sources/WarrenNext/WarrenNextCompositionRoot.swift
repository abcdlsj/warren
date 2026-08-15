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
    @State private var workspaceCreatorProjectID: ProjectID?
    @State private var terminalSearchPresented = false
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
            webStatus: remoteModel.webStatus,
            endpointOptions: endpointOptions,
            selectedEndpointID: selectedEndpointID,
            onSelectEndpoint: selectEndpoint,
            onWebStart: { remoteModel.startWebFromUI() },
            onWebStop: { remoteModel.stopWeb() },
            onWebOpenURL: { remoteModel.openWebURL($0) },
            onWebCopyURL: { remoteModel.copyWebURL($0) }
        ) { context in
            WarrenNextTerminalSurfaceView(
                context: context,
                surfaces: remoteModel.mountedSurfaces,
                onFocused: { sessionID, size in
                    remoteModel.focus(sessionID: sessionID, size: size)
                },
                onBlurred: { sessionID in
                    remoteModel.blur(sessionID: sessionID)
                },
                searchPresented: $terminalSearchPresented
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
            WarrenNextSupersetImportView(preview: preview) { selectedPreview in
                supersetImportPreview = nil
                isSupersetImporting = true
                Task {
                    await remoteModel.commitSupersetImport(selectedPreview)
                    isSupersetImporting = false
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
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.copyLocalURL)) { _ in
            remoteModel.copyLocalWebURL()
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.findInTerminal)) { _ in
            terminalSearchPresented = true
        }
        .onChange(of: terminalFontFamily) { _, _ in updateTerminalFont() }
        .onChange(of: terminalFontSize) { _, _ in updateTerminalFont() }
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.startCloudflare)) { _ in
            remoteModel.startCloudflareWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.stopCloudflare)) { _ in
            remoteModel.stopCloudflareWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.startTailscale)) { _ in
            remoteModel.startTailscaleWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.stopTailscale)) { _ in
            remoteModel.stopTailscaleWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.copySecureURL)) { _ in
            remoteModel.copySecureWebURL()
        }
        .task {
            updateTerminalFont()
            restoreEndpointSelection()
        }
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
            remoteModel.createSession(workspaceID: workspaceID, request: .shell)
        } else {
            remoteModel.perform(action)
        }
    }

    private var endpointOptions: [WarrenDesktopEndpointOption] {
        let local = WarrenDesktopEndpointOption(id: "local", label: "Local", isLocal: true)
        let configured = endpointCatalog
            .filter { $0.id != local.id }
            .map { endpoint in
                WarrenDesktopEndpointOption(id: endpoint.id, label: endpoint.name)
            }
        return [local] + configured
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
    let onConfirm: (SupersetImportPreview) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedProjectIDs: Set<String>

    init(preview: SupersetImportPreview, onConfirm: @escaping (SupersetImportPreview) -> Void) {
        self.preview = preview
        self.onConfirm = onConfirm
        _selectedProjectIDs = State(initialValue: preview.readyProjectIDs)
    }

    private var allWorkspaces: [SupersetImportWorkspaceCandidate] {
        preview.projects.flatMap(\.workspaces)
    }

    private var selectedPreview: SupersetImportPreview {
        preview.selectingProjects(selectedProjectIDs)
    }

    private var missingPathCount: Int {
        allWorkspaces.filter { $0.status == .missing }.count
    }

    private var invalidPathCount: Int {
        allWorkspaces.filter { $0.status == .invalid }.count
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            header(tokens: tokens)

            divider(tokens: tokens)

            summary(tokens: tokens)

            projectList(tokens: tokens)

            divider(tokens: tokens)

            footer(tokens: tokens)
        }
        .frame(
            minWidth: 680,
            idealWidth: 720,
            maxWidth: 720,
            minHeight: 520,
            idealHeight: 580
        )
        .background(tokens.popoverSurface)
    }

    private func divider(tokens: WarrenColorTokens) -> some View {
        Rectangle()
            .fill(tokens.border)
            .frame(height: WarrenSpacing.hairline)
    }

    private func header(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            Text("Import from Superset")
                .font(WarrenTypography.dialogTitle)
            Text("One-time copy. Warren does not modify or synchronize Superset.")
                .font(WarrenTypography.body)
                .foregroundStyle(tokens.mutedForeground)
        }
        .padding(.horizontal, WarrenSpacing.large)
        .padding(.top, WarrenSpacing.large)
        .padding(.bottom, WarrenSpacing.standard)
    }

    private func summary(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.small) {
            summaryMetric(preview.readyProjectCount, label: "ready projects", tokens: tokens)
            separator(tokens: tokens)
            summaryMetric(preview.readyWorkspaceCount, label: "ready workspaces", tokens: tokens)
            separator(tokens: tokens)
            summaryMetric(missingPathCount, label: "missing paths", tokens: tokens)
            separator(tokens: tokens)
            summaryMetric(invalidPathCount, label: "invalid paths", tokens: tokens)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, WarrenSpacing.large)
        .padding(.vertical, WarrenSpacing.medium)
    }

    private func summaryMetric(
        _ value: Int,
        label: String,
        tokens: WarrenColorTokens
    ) -> some View {
        HStack(spacing: WarrenSpacing.xs) {
            Text("\(value)")
                .font(WarrenTypography.bodyEmphasis)
                .foregroundStyle(tokens.foreground)
            Text(label)
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)
        }
    }

    private func separator(tokens: WarrenColorTokens) -> some View {
        Text("·")
            .font(WarrenTypography.supporting)
            .foregroundStyle(tokens.mutedForeground)
            .accessibilityHidden(true)
    }

    private func projectList(tokens: WarrenColorTokens) -> some View {
        ScrollView {
            if preview.projects.isEmpty {
                Text("No projects found in Superset.")
                    .font(WarrenTypography.body)
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, WarrenSpacing.large)
            } else {
                LazyVStack(spacing: WarrenSpacing.xs) {
                    ForEach(preview.projects) { project in
                        projectRow(project, tokens: tokens)
                    }
                }
                .padding(WarrenSpacing.small)
            }
        }
        .frame(maxHeight: .infinity)
        .background(tokens.chromeSurface)
        .clipShape(.rect(cornerRadius: WarrenRadius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: WarrenRadius.medium)
                .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
        }
        .padding(.horizontal, WarrenSpacing.large)
        .padding(.vertical, WarrenSpacing.medium)
    }

    private func projectRow(
        _ project: SupersetImportProjectCandidate,
        tokens: WarrenColorTokens
    ) -> some View {
        let isSelectable = project.status == .ready
        let isSelected = selectedProjectIDs.contains(project.id)
        return HStack(spacing: WarrenSpacing.medium) {
            Toggle("", isOn: selectionBinding(for: project))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .tint(Color.accentColor)
                .disabled(!isSelectable)
                .accessibilityLabel(project.name)

            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                HStack(spacing: WarrenSpacing.compact) {
                    Text(project.name)
                        .font(WarrenTypography.bodyEmphasis)
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                    Text(project.status.rawValue.capitalized)
                        .font(WarrenTypography.badge)
                        .foregroundStyle(statusColor(project.status, tokens: tokens))
                }
                Text(project.repositoryPath)
                    .font(WarrenTypography.code)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: WarrenSpacing.medium)

            VStack(alignment: .trailing, spacing: WarrenSpacing.xxs) {
                Text(workspaceSummary(project))
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
                if let diagnostic = project.diagnostic {
                    Text(diagnostic)
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(statusColor(project.status, tokens: tokens))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 190, alignment: .trailing)
        }
        .padding(.horizontal, WarrenSpacing.medium)
        .padding(.vertical, WarrenSpacing.compact)
        .background(isSelected ? tokens.fillSelected : Color.clear)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .accessibilityElement(children: .contain)
    }

    private func selectionBinding(for project: SupersetImportProjectCandidate) -> Binding<Bool> {
        Binding(
            get: { selectedProjectIDs.contains(project.id) },
            set: { isOn in
                if isOn {
                    selectedProjectIDs.insert(project.id)
                } else {
                    selectedProjectIDs.remove(project.id)
                }
            }
        )
    }

    private func workspaceSummary(_ project: SupersetImportProjectCandidate) -> String {
        let ready = project.workspaces.filter { $0.status == .ready }.count
        return "\(ready)/\(project.workspaces.count) workspaces"
    }

    private func statusColor(
        _ status: SupersetImportCandidateStatus,
        tokens: WarrenColorTokens
    ) -> Color {
        switch status {
        case .ready:
            Color.green
        case .missing:
            Color.orange
        case .invalid:
            tokens.destructive
        }
    }

    private func footer(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            Text("\(selectedProjectIDs.count) of \(preview.readyProjectCount) projects selected")
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)

            Spacer(minLength: 0)

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Import") {
                dismiss()
                onConfirm(selectedPreview)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedProjectIDs.isEmpty)
        }
        .padding(.horizontal, WarrenSpacing.large)
        .padding(.vertical, WarrenSpacing.standard)
    }
}

private struct WarrenNextTerminalSurfaceView: View {
    let context: WarrenDesktopTerminalContext
    let surfaces: [GhosttySurface]
    let onFocused: (TerminalSessionID, TerminalSize?) -> Void
    let onBlurred: (TerminalSessionID) -> Void
    @Binding var searchPresented: Bool
    @State private var searchQuery = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var focusDriver = GhosttyFocusDriver()

    private var activeSurface: GhosttySurface? {
        surfaces.first { $0.id == context.tab.sessionID }
    }

    var body: some View {
        Group {
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
                                viewportSize: proxy.size,
                                onFocused: {
                                    onFocused(
                                        surface.id,
                                        surface.state.surfaceSize.flatMap {
                                            TerminalSize(columns: Int($0.columns), rows: Int($0.rows))
                                        }
                                    )
                                },
                                onBlurred: {
                                    onBlurred(surface.id)
                                }
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
        .overlay(alignment: .topTrailing) {
            if searchPresented, activeSurface != nil {
                WarrenTerminalSearchBar(
                    presented: $searchPresented,
                    query: $searchQuery,
                    fieldFocused: $searchFieldFocused,
                    surface: activeSurface
                )
                .padding(WarrenSpacing.compact)
            }
        }
        .onChange(of: searchPresented) { _, presented in
            if presented {
                searchQuery = activeSurface?.readSelection() ?? ""
                searchFieldFocused = true
            } else {
                searchQuery = ""
                activeSurface?.endSearch()
            }
        }
        .onChange(of: context.tab.sessionID) { _, _ in
            for surface in surfaces { surface.endSearch() }
            searchQuery = ""
            searchPresented = false
        }
    }
}

private struct WarrenTerminalSearchBar: View {
    @Binding var presented: Bool
    @Binding var query: String
    @FocusState.Binding var fieldFocused: Bool
    let surface: GhosttySurface?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)

            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($fieldFocused)
                .frame(width: 170)
                .onSubmit {
                    surface?.navigateSearch(.next)
                }

            Button {
                surface?.navigateSearch(.previous)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 20, height: 20)
            }
            .help("Previous match (⇧⏎)")

            Button {
                surface?.navigateSearch(.next)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 20, height: 20)
            }
            .help("Next match (⏎)")

            Button {
                presented = false
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .keyboardShortcut(.cancelAction)
            .help("Close search (esc)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tokens.mutedForeground)
        .padding(.horizontal, WarrenSpacing.small)
        .frame(height: 30)
        .background(tokens.popoverSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
        }
        .onAppear {
            surface?.search(for: query)
            fieldFocused = true
        }
        .onChange(of: query) { _, newValue in
            surface?.search(for: newValue)
        }
    }
}
