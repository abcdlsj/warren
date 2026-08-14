import Foundation
import AppKit
import GhosttyAdapter
import Observation
import WarrenApplication
import WarrenClientCore
import WarrenDesktop
import WarrenDomain
import WarrenStateStore

extension WarrenRemoteEndpointConfiguration {
    static func localDaemon() -> Self {
        let environment = ProcessInfo.processInfo.environment
        let tokenURL: URL
        if let configured = environment["WARREN_TOKEN_FILE"], !configured.isEmpty {
            tokenURL = URL(fileURLWithPath: configured)
        } else if let stateHome = environment["XDG_STATE_HOME"], !stateHome.isEmpty {
            tokenURL = URL(fileURLWithPath: stateHome).appendingPathComponent("warren/token")
        } else {
            tokenURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/state/warren/token")
        }
        let token = (try? String(contentsOf: tokenURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(name: "Local", url: "http://127.0.0.1:8789", token: token, ssh: nil)
    }
}

struct WarrenRemoteEndpointConfiguration: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let url: String
    let token: String
    let ssh: String?

    var id: String { name }
}

private struct WarrenEndpointConfigurationFile: Decodable {
    let current: String?
    let endpoints: [String: WarrenRemoteEndpointConfiguration]
}

enum WarrenEndpointCatalog {
    static func load() -> (current: String?, endpoints: [WarrenRemoteEndpointConfiguration]) {
        let environment = ProcessInfo.processInfo.environment
        let configURL: URL
        if let value = environment["WARREN_CONFIG"], !value.isEmpty {
            configURL = URL(fileURLWithPath: value)
        } else if let value = environment["XDG_CONFIG_HOME"], !value.isEmpty {
            configURL = URL(fileURLWithPath: value).appendingPathComponent("warren/config.json")
        } else {
            configURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/warren/config.json")
        }
        guard let data = try? Data(contentsOf: configURL),
              let file = try? JSONDecoder().decode(WarrenEndpointConfigurationFile.self, from: data) else {
            return (nil, [])
        }
        return (file.current, file.endpoints.values.sorted { $0.name < $1.name })
    }
}

private struct RemoteRoster: Decodable, Sendable {
    struct Host: Decodable, Sendable { let id: String; let name: String }
    struct Project: Decodable, Sendable { let id: String; let name: String; let path: String }
    struct Workspace: Decodable, Sendable {
        let id: String
        let project: String
        let name: String
        let path: String
        let branch: String?
    }
    struct Session: Decodable, Sendable {
        let id: String
        let workspace: String
        let title: String
        let kind: String
        let command: String?
        let lifecycle: String
    }

    let host: Host
    let projects: [Project]
    let workspaces: [Workspace]
    let sessions: [Session]
}

private enum RemoteWireEvent: Sendable {
    case roster(RemoteRoster)
    case output(Data)
    case disconnected(String)
}

private actor WarrenRemoteWire {
    private static let outputChunkBytes = 128 * 1024
    private let configuration: WarrenRemoteEndpointConfiguration
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuations: [String: CheckedContinuation<Data, Error>] = [:]
    private var pendingInput = Data()
    private var inputTask: Task<Void, Never>?
    private let eventBuffer = WarrenLosslessAsyncBuffer<RemoteWireEvent>(capacity: 64)

    init(configuration: WarrenRemoteEndpointConfiguration) { self.configuration = configuration }

    nonisolated func events() -> AsyncStream<RemoteWireEvent> { eventBuffer.stream }

    func connect() async throws {
        guard task == nil else { return }
        guard var components = URLComponents(string: configuration.url) else {
            throw URLError(.badURL)
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/ws"
        guard let url = components.url else { throw URLError(.badURL) }
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        try await socket.send(.string(Self.json([
            "t": "auth",
            "token": configuration.token,
        ])))
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
    }

    func close() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        inputTask?.cancel()
        inputTask = nil
        pendingInput.removeAll(keepingCapacity: true)
        eventBuffer.finish()
        for continuation in continuations.values {
            continuation.resume(throwing: URLError(.cancelled))
        }
        continuations.removeAll()
    }

    func request(_ method: String, params: [String: String] = [:]) async throws -> Data {
        guard let task else { throw URLError(.notConnectedToInternet) }
        let id = UUID().uuidString.lowercased()
        let text = Self.json(["t": "request", "id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
            Task {
                do { try await task.send(.string(text)) }
                catch { self.failRequest(id, error: error) }
            }
        }
    }

    func sendInput(_ data: Data) {
        guard !data.isEmpty else { return }
        pendingInput.append(data)
        guard inputTask == nil else { return }
        inputTask = Task { [weak self] in await self?.drainInput() }
    }

    private func drainInput() async {
        defer { inputTask = nil }
        while !Task.isCancelled, !pendingInput.isEmpty {
            let data = pendingInput
            pendingInput.removeAll(keepingCapacity: true)
            guard let task else { return }
            do {
                try await task.send(.data(data))
            } catch {
                _ = await eventBuffer.send(.disconnected(String(describing: error)))
                return
            }
        }
    }

    private func failRequest(_ id: String, error: Error) {
        continuations.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                switch try await socket.receive() {
                case .data(let data):
                    guard await emitOutput(data) else { return }
                case .string(let text):
                    guard await handleText(Data(text.utf8)) else { return }
                @unknown default:
                    break
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            _ = await eventBuffer.send(.disconnected(String(describing: error)))
        }
    }

    private func emitOutput(_ data: Data) async -> Bool {
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.outputChunkBytes, data.count)
            let chunk = offset == 0 && end == data.count
                ? data
                : Data(data[offset..<end])
            guard await eventBuffer.send(.output(chunk)) else { return false }
            offset = end
        }
        return true
    }

    private func handleText(_ data: Data) async -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String else { return true }
        if type == "response", let id = object["id"] as? String,
           let continuation = continuations.removeValue(forKey: id) {
            if object["ok"] as? Bool == true {
                let result = object["result"] ?? NSNull()
                let encoded = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("null".utf8)
                continuation.resume(returning: encoded)
            } else {
                continuation.resume(throwing: NSError(
                    domain: "WarrenRemote",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: object["error"] as? String ?? "Remote request failed"]
                ))
            }
        } else if type == "roster", let state = object["state"],
                  let encoded = try? JSONSerialization.data(withJSONObject: state),
                  let roster = try? JSONDecoder().decode(RemoteRoster.self, from: encoded) {
            return await eventBuffer.send(.roster(roster))
        } else if type == "error" {
            return await eventBuffer.send(.disconnected(
                object["error"] as? String ?? "Remote authentication failed"
            ))
        }
        return true
    }

    private nonisolated static func json(_ value: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value)
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
@Observable
final class WarrenRemoteApplicationModel {
    private(set) var projection = WarrenDesktopProjection.empty(host: WarrenDomain.Host(name: "Server"))
    private(set) var navigation = WarrenDesktopNavigationState(selection: nil, selectedTabID: nil)
    private(set) var mountedSurfaces: [GhosttySurface] = []
    private(set) var issue: Error?
    private(set) var webRelayStatus = WarrenDesktopWebRelayStatus()

    @ObservationIgnored private var wire: WarrenRemoteWire?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var selectedSessionID: TerminalSessionID?
    @ObservationIgnored private var currentRoster: RemoteRoster?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?

    func connect(_ configuration: WarrenRemoteEndpointConfiguration) {
        disconnect()
        if configuration.url.hasPrefix("http://127.0.0.1:8789"),
           !configuration.token.isEmpty,
           let url = URL(string: "http://127.0.0.1:8788/#t=\(configuration.token)") {
            webRelayStatus = WarrenDesktopWebRelayStatus(isRunning: true, localURL: url)
        }
        projection = WarrenDesktopProjection.empty(host: WarrenDomain.Host(name: configuration.name))
        let wire = WarrenRemoteWire(configuration: configuration)
        self.wire = wire
        let events = wire.events()
        eventTask = Task { @MainActor [weak self] in
            do {
                try await wire.connect()
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.consume(event)
                }
            } catch {
                self?.present(error)
            }
        }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        if let wire { Task { await wire.close() } }
        wire = nil
        currentRoster = nil
        selectedSessionID = nil
        resizeTask?.cancel()
        resizeTask = nil
        mountedSurfaces.removeAll()
        webRelayStatus = WarrenDesktopWebRelayStatus()
    }

    func createWorkspace(projectID: ProjectID, request creation: WorkspaceCreationRequest) {
        request("workspace.create", params: [
            "project": projectID.description,
            "branch": creation.branch,
            "name": creation.displayName,
            "path": creation.path,
        ])
    }

    func createSession(workspaceID: WorkspaceID, request launch: TerminalSessionLaunchRequest) {
        request("session.create", params: [
            "workspace": workspaceID.description,
            "command": launch.command ?? "",
            "kind": launch.kind.rawValue,
            "title": launch.title ?? "",
        ])
    }

    func addProject(_ folder: URL) async {
        request("project.add", params: ["path": folder.path, "name": folder.lastPathComponent])
    }

    func updateTerminalFont(_ preference: TerminalFontPreference) {}
    func startWebRelayFromUI() {}
    func stopWebRelay() {}
    func openWebRelayURL(_ url: URL) { NSWorkspace.shared.open(url) }
    func copyWebRelayURL(_ url: URL) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
    func copyLocalWebURL() {
        if let url = webRelayStatus.localURL { copyWebRelayURL(url) }
    }
    func startCloudflareWebAccess() {}
    func stopCloudflareWebAccess() {}
    func startTailscaleWebAccess() {}
    func stopTailscaleWebAccess() {}
    func copySecureWebURL() {}

    func previewSupersetImport(from databaseURL: URL) async throws -> SupersetImportPreview {
        let source = try SupersetImportSource(databaseURL: databaseURL)
        return try await source.preview()
    }

    func commitSupersetImport(_ preview: SupersetImportPreview) async {
        guard let wire else { return }
        do {
            for project in preview.projects where project.status == .ready {
                let data = try await wire.request("project.add", params: [
                    "path": project.repositoryPath,
                    "name": project.name,
                ])
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = object["id"] as? String else { continue }
                for workspace in project.workspaces where workspace.status == .ready {
                    if workspace.path == project.repositoryPath { continue }
                    _ = try await wire.request("workspace.create", params: [
                        "project": id,
                        "branch": workspace.branch ?? "main",
                        "name": workspace.name,
                        "path": workspace.path,
                    ])
                }
            }
        } catch {
            present(error)
        }
    }

    func perform(_ action: WarrenDesktopAction) {
        navigation = WarrenDesktopNavigationReducer.reduce(navigation, action: action, in: projection)
        switch action {
        case .selectProject, .selectWorkspace:
            Task { await attachSelectedSession() }
        case .selectTab:
            Task { await attachSelectedSession() }
        case .openSession(let id):
            selectSession(id)
        case .deleteSession(let id):
            request("session.delete", params: ["id": id.description])
        case .closeTab(let tabID):
            if let id = projection.tabs.first(where: { $0.id == tabID })?.sessionID {
                request("session.delete", params: ["id": id.description])
            }
        case .closeOtherTabs(let tabID):
            guard let workspaceID = projection.workspaceID(forTabID: tabID) else { return }
            for tab in projection.tabs(in: workspaceID) where tab.id != tabID {
                if let id = tab.sessionID { request("session.delete", params: ["id": id.description]) }
            }
        case .closeAllTabs:
            guard let workspaceID = selectedWorkspaceID else { return }
            for tab in projection.tabs(in: workspaceID) {
                if let id = tab.sessionID { request("session.delete", params: ["id": id.description]) }
            }
        case .launchSession(let workspaceID, let launch):
            createSession(workspaceID: workspaceID, request: launch)
        case .addProject:
            present(NSError(domain: "WarrenRemote", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "远端 Project 必须用远端路径。请运行 warren --endpoint <server> project add /path。",
            ]))
        case .renameWorkspace:
            present(NSError(domain: "WarrenRemote", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "远端 Workspace 重命名尚未开放；可继续使用 CLI 管理。",
            ]))
        case .importSuperset, .requestNewWorkspace, .requestNewSession, .moveTab,
             .toggleInspector, .toggleSidebar:
            break
        }
    }

    func sendInput(_ data: Data) async {
        guard let wire else { return }
        await wire.sendInput(data)
    }

    func resize(columns: Int, rows: Int) {
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(24))
                guard let self, let wire = self.wire else { return }
                _ = try await wire.request("session.resize", params: [
                    "cols": String(columns),
                    "rows": String(rows),
                ])
            } catch is CancellationError {
                return
            } catch {
                self?.present(error)
            }
        }
    }

    func report(_ error: Error) { present(error) }

    private func request(_ method: String, params: [String: String]) {
        guard let wire else { return }
        Task { @MainActor [weak self] in
            do { _ = try await wire.request(method, params: params) }
            catch { self?.present(error) }
        }
    }

    private func consume(_ event: RemoteWireEvent) async {
        switch event {
        case .roster(let roster):
            currentRoster = roster
            apply(roster)
        case .output(let data):
            await feedOutput(data)
        case .disconnected(let detail):
            projection = projection.withConnectionState(.failed)
            present(NSError(domain: "WarrenRemote", code: 4, userInfo: [NSLocalizedDescriptionKey: detail]))
        }
    }

    private func feedOutput(_ data: Data) async {
        guard !data.isEmpty,
              let surface = mountedSurfaces.first,
              surface.id == selectedSessionID else { return }
        let interval = WarrenPerformance.signposter.beginInterval("Remote Ghostty Feed")
        defer { WarrenPerformance.signposter.endInterval("Remote Ghostty Feed", interval) }
        let budget = 128 * 1024
        var offset = 0
        while offset < data.count,
              !Task.isCancelled,
              mountedSurfaces.first === surface {
            let end = min(offset + budget, data.count)
            surface.receive(offset == 0 && end == data.count
                ? data
                : Data(data[offset..<end]))
            offset = end
            guard offset < data.count else { return }
            do {
                try await Task.sleep(for: .milliseconds(8))
            } catch {
                return
            }
        }
    }

    private func apply(_ roster: RemoteRoster) {
        guard let hostID = HostID(uuidString: roster.host.id) else { return }
        let host = WarrenDomain.Host(id: hostID, name: roster.host.name)
        let projects = roster.projects.compactMap { value -> Project? in
            guard let id = ProjectID(uuidString: value.id) else { return nil }
            return Project(id: id, hostID: hostID, name: value.name, rootPath: value.path)
        }
        let workspaces = roster.workspaces.compactMap { value -> Workspace? in
            guard let id = WorkspaceID(uuidString: value.id),
                  let projectID = ProjectID(uuidString: value.project) else { return nil }
            return Workspace(id: id, projectID: projectID, name: value.name, path: value.path, branch: value.branch)
        }
        let workspacePaths = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.path) })
        let remoteSessions = roster.sessions.compactMap { value -> (RemoteRoster.Session, TerminalSessionID, WorkspaceID)? in
            guard let id = TerminalSessionID(uuidString: value.id),
                  let workspaceID = WorkspaceID(uuidString: value.workspace) else { return nil }
            return (value, id, workspaceID)
        }
        let sessions = remoteSessions.map { value, id, workspaceID in
            WarrenDesktopSession(
                id: id,
                workspaceID: workspaceID,
                tabID: Self.tabID(id),
                title: value.title,
                kind: TerminalSessionKind(rawValue: value.kind) ?? .custom,
                state: value.lifecycle == "running" ? .attached : .exited,
                runtimeProcess: value.command ?? "",
                workingDirectory: workspacePaths[workspaceID] ?? ""
            )
        }
        let tabs = remoteSessions.map { value, id, _ in
            ClientTab(
                id: Self.tabID(id),
                title: value.title,
                sessionID: id,
                kind: TerminalSessionKind(rawValue: value.kind) ?? .custom
            )
        }
        let sessionWorkspaces = Dictionary(uniqueKeysWithValues: remoteSessions.map { ($0.1, $0.2) })
        projection = WarrenDesktopProjection(
            host: host,
            projects: projects,
            workspaces: workspaces,
            sessions: sessions,
            tabs: tabs,
            sessionWorkspaceIDs: sessionWorkspaces,
            connectionState: .attached
        )
        navigation = WarrenDesktopNavigationReducer.reconcile(navigation, with: projection)
        if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = nil
            mountedSurfaces.removeAll()
        }
    }

    private func attachSelectedSession() async {
        guard let tabID = navigation.selectedTabID,
              let sessionID = projection.tabs.first(where: { $0.id == tabID })?.sessionID,
              sessionID != selectedSessionID,
              let session = projection.sessions.first(where: { $0.id == sessionID }),
              let wire else { return }
        do {
            _ = try await wire.request("session.attach", params: ["id": sessionID.description])
            selectedSessionID = sessionID
            let surface = GhosttySurface(
                id: sessionID,
                attachmentID: TerminalAttachmentID(),
                workingDirectory: session.workingDirectory,
                onInput: { [weak self] data in Task { await self?.sendInput(data) } },
                onResize: { [weak self] columns, rows in Task { @MainActor in self?.resize(columns: columns, rows: rows) } }
            )
            mountedSurfaces = [surface]
        } catch {
            present(error)
        }
    }

    private func selectSession(_ id: TerminalSessionID) {
        guard let session = projection.sessions.first(where: { $0.id == id }) else { return }
        navigation = WarrenDesktopNavigationState(
            selection: .workspace(session.workspaceID),
            selectedTabID: Self.tabID(id)
        )
        Task { await attachSelectedSession() }
    }

    private var selectedWorkspaceID: WorkspaceID? {
        switch navigation.selection {
        case .workspace(let id): id
        case .project(let id): projection.firstWorkspace(in: id)?.id
        case nil: nil
        }
    }

    private func present(_ error: Error) { issue = error }
    private static func tabID(_ id: TerminalSessionID) -> String { "remote-\(id.description)" }
}

private extension WarrenDesktopProjection {
    func withConnectionState(_ state: WarrenDesktopConnectionState) -> Self {
        Self(
            host: host,
            groups: groups,
            sessions: sessions,
            tabs: tabs,
            sessionWorkspaceIDs: sessionWorkspaceIDs,
            tabWorkspaceIDs: tabWorkspaceIDs,
            inspector: inspector,
            connectionState: state
        )
    }
}
