import BurrowApplication
import BurrowDomain
import BurrowHost
import CryptoKit
import Darwin
import Foundation
import Security

/// Local WebSocket relay for the browser client.
///
/// The relay is a small POSIX HTTP+WebSocket server on one port: `GET /`
/// serves the bundled web page, `GET /ws` upgrades to WebSocket, and binary
/// frames carry PTY bytes. Cloudflare needs the origin to answer plain HTTP
/// health checks, so the same port must speak both protocols.
@MainActor
public final class WebRelayServer {
    nonisolated public static let defaultPort: UInt16 = 8788
    public static let startTunnel = Notification.Name("WebRelay.startTunnel")
    public static let stopTunnel = Notification.Name("WebRelay.stopTunnel")
    public static let copyWebURL = Notification.Name("WebRelay.copyWebURL")
    public static let startTailscale = Notification.Name("WebRelay.startTailscale")
    public static let stopTailscale = Notification.Name("WebRelay.stopTailscale")
    public static let startFunnel = Notification.Name("WebRelay.startFunnel")
    public static let stopFunnel = Notification.Name("WebRelay.stopFunnel")

    fileprivate let service: BurrowApplicationService
    private var listenFD: Int32 = -1
    private var serverSource: DispatchSourceRead?
    private var connections: [Int32: SocketConnection] = [:]
    private var tunnelProcess: Process?
    public private(set) var tunnelURL: URL?
    public private(set) var tailscaleURL: URL?
    public private(set) var funnelURL: URL?
    public private(set) var listeningPort: UInt16?

    public init(service: BurrowApplicationService) {
        self.service = service
    }

    public func start(port: UInt16 = WebRelayServer.defaultPort) {
        guard serverSource == nil else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        // Reachability adapters proxy this loopback listener explicitly.
        // Starting Burrow alone must never expose terminal control to the LAN.
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolvedPort = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLength)
            }
        } == 0 ? UInt16(bigEndian: boundAddress.sin_port) : port
        Self.log("listening \(resolvedPort)")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.resume()
        listenFD = fd
        serverSource = source
        listeningPort = resolvedPort
    }

    public func stop() {
        serverSource?.cancel()
        serverSource = nil
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
        listeningPort = nil
        let peers = Array(connections.values)
        for connection in peers {
            connection.close()
        }
        connections.removeAll()
    }

    private func acceptPending() {
        while true {
            let client = Darwin.accept(listenFD, nil, nil)
            if client < 0 { break }
            _ = fcntl(client, F_SETFL, O_NONBLOCK)
            var nodelay: Int32 = 1
            setsockopt(
                client,
                IPPROTO_TCP,
                TCP_NODELAY,
                &nodelay,
                socklen_t(MemoryLayout<Int32>.size)
            )
            var noSignal: Int32 = 1
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            )
            Self.log("accept \(client)")
            let connection = SocketConnection(fd: client, server: self)
            connections[client] = connection
            connection.start()
        }
    }

    fileprivate func drop(_ fd: Int32) {
        Self.log("drop \(fd)")
        guard let connection = connections.removeValue(forKey: fd) else { return }
        connection.close()
    }

    nonisolated fileprivate static func log(_ message: String) {
        let url = URL(fileURLWithPath: "/tmp/web-relay-posix.log")
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Web page / tunnel / token

    public static var webPageURL: URL? {
        if let bundled = Bundle.main.url(forResource: "web", withExtension: "html") {
            return bundled
        }
        return Bundle.module.url(forResource: "web", withExtension: "html")
    }

    public static var webPageHTML: String? {
        guard let url = webPageURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func resourceData(named name: String, extension fileExtension: String) -> Data? {
        let url = Bundle.main.url(forResource: name, withExtension: fileExtension)
            ?? Bundle.module.url(forResource: name, withExtension: fileExtension)
        return url.flatMap { try? Data(contentsOf: $0) }
    }

    public static var accessToken: String {
        RelayPairingToken.current
    }

    /// Installs the current managed hook definitions and returns the small
    /// environment inherited only by Burrow-created terminal Sessions.
    public static func installAgentHooks() -> [String: String] {
        AgentHookInstaller.install(port: defaultPort, token: accessToken)
    }

    public static var agentHookEnvironment: [String: String] {
        [
            "BURROW_HOOK_URL": "http://127.0.0.1:\(defaultPort)/hook",
            "BURROW_HOOK_TOKEN": accessToken,
        ]
    }

    public static var webPageURLWithToken: URL? {
        webPageURL(host: nil)
    }

    public static var localWebURL: URL? {
        URL(string: "http://127.0.0.1:\(defaultPort)/#t=\(accessToken)")
    }

    public var secureWebURL: URL? {
        guard let base = tunnelURL ?? tailscaleURL ?? funnelURL else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.fragment = "t=\(Self.accessToken)"
        return components?.url
    }

    public static func webPageURL(host: String? = nil) -> URL? {
        guard let url = webPageURL else { return nil }
        var suffix = "#t=\(accessToken)"
        if let host, !host.isEmpty {
            suffix += "&host=\(host)"
        }
        return URL(string: url.absoluteString + suffix)
    }

    public static func webPageDataURL(host: String? = nil) -> URL? {
        guard let html = webPageHTML else { return nil }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "host", value: host ?? ""),
            URLQueryItem(name: "t", value: accessToken),
        ]
        guard let params = components.percentEncodedQuery else { return nil }
        let replaced = html.replacingOccurrences(
            of: "__BURROW_INJECTED_PARAMS__",
            with: params
        )
        guard let data = replaced.data(using: .utf8) else { return nil }
        return URL(string: "data:text/html;base64,\(data.base64EncodedString())")
    }

    public var isTunnelRunning: Bool {
        tunnelProcess != nil && tunnelURL != nil
    }

    public var isTailscaleRunning: Bool {
        tailscaleURL != nil
    }

    public var isFunnelRunning: Bool {
        funnelURL != nil
    }

    // MARK: - cloudflared

    public func startTunnel() {
        guard tunnelProcess == nil else { return }
        guard let binary = Self.cloudflaredBinary else { return }
        let process = Process()
        process.executableURL = binary
        process.environment = Self.sanitizedProcessEnvironment
        process.arguments = [
            "tunnel",
            "--url",
            "http://127.0.0.1:\(Self.defaultPort)",
            "--no-autoupdate",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        tunnelURL = nil
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self.scanTunnelOutput(text) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.tunnelProcess === process else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.tunnelProcess = nil
                self.tunnelURL = nil
            }
        }
        do {
            try process.run()
            tunnelProcess = process
        } catch {
            tunnelProcess = nil
        }
    }

    public func stopTunnel() {
        tunnelProcess?.terminate()
        tunnelProcess = nil
        tunnelURL = nil
    }

    private func scanTunnelOutput(_ text: String) {
        guard tunnelURL == nil,
              let url = Self.parseTunnelURL(from: text) else { return }
        tunnelURL = url
        try? url.absoluteString.write(
            to: URL(fileURLWithPath: "/tmp/burrow-tunnel-url.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    internal static func parseTunnelURL(from text: String) -> URL? {
        guard let range = text.range(
            of: #"https://[a-zA-Z0-9-]+\.trycloudflare\.com"#,
            options: .regularExpression
        ) else { return nil }
        return URL(string: String(text[range]))
    }

    // MARK: - tailscale

    public func startTailscale() async {
        guard tailscaleURL == nil,
              let binary = Self.tailscaleBinary else { return }
        _ = await runProcess(
            binary: binary,
            arguments: ["serve", "--bg", "8788"]
        )
        for _ in 0..<30 {
            if let output = await runProcess(
                binary: binary,
                arguments: ["serve", "status", "--json"]
            ), let url = Self.parseTailscaleURL(from: output) {
                tailscaleURL = url
                try? url.absoluteString.write(
                    to: URL(fileURLWithPath: "/tmp/burrow-tailscale-url.txt"),
                    atomically: true,
                    encoding: .utf8
                )
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    public func stopTailscale() async {
        guard let binary = Self.tailscaleBinary else { return }
        _ = await runProcess(
            binary: binary,
            arguments: ["serve", "--https=443", "off"]
        )
        tailscaleURL = nil
    }

    public func startFunnel() async {
        guard funnelURL == nil,
              let binary = Self.tailscaleBinary else { return }
        _ = await runProcess(
            binary: binary,
            arguments: ["funnel", "--bg", "--yes", "8788"]
        )
        for _ in 0..<30 {
            if let output = await runProcess(
                binary: binary,
                arguments: ["funnel", "status", "--json"]
            ), let url = Self.parseTailscaleURL(from: output) {
                funnelURL = url
                try? url.absoluteString.write(
                    to: URL(fileURLWithPath: "/tmp/burrow-funnel-url.txt"),
                    atomically: true,
                    encoding: .utf8
                )
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    public func stopFunnel() async {
        guard let binary = Self.tailscaleBinary else { return }
        _ = await runProcess(
            binary: binary,
            arguments: ["funnel", "reset"]
        )
        funnelURL = nil
    }

    internal static func parseTailscaleURL(from json: String) -> URL? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let object = object as? [String: Any],
              let web = (object["Web"] as? [String: Any]) ?? (object["Funnel"] as? [String: Any]),
              let hostKey = web.keys.first,
              let host = hostKey.split(separator: ":").first else {
            return nil
        }
        return URL(string: "https://\(host)/")
    }

    private static var cloudflaredBinary: URL? {
        let candidates = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
            "/usr/bin/cloudflared",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static var tailscaleBinary: URL? {
        let candidates = [
            "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func runProcess(
        binary: URL,
        arguments: [String]
    ) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = binary
            process.environment = Self.sanitizedProcessEnvironment
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private nonisolated static var sanitizedProcessEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "BURROW_CONTROL_PLANE_URL")
        environment.removeValue(forKey: "BURROW_CONTROL_PLANE_HOST_ID")
        environment.removeValue(forKey: "BURROW_CONTROL_PLANE_HOST_TOKEN")
        return environment
    }

    // MARK: - Relay logic

    fileprivate func rosterJSON() async -> String {
        let snapshot = await service.snapshot()
        let projects = snapshot.projects.map {
            ["id": $0.id.description, "name": $0.name, "path": $0.rootPath]
        }
        let workspaces = snapshot.workspaces.map {
            [
                "id": $0.id.description,
                "project": $0.projectID.description,
                "name": $0.name,
                "branch": $0.branch ?? "",
            ]
        }
        let sessions = snapshot.sessions.map {
            [
                "id": $0.id.description,
                "workspace": $0.workspaceID.description,
                "title": $0.title,
                "kind": $0.kind.rawValue,
                "state": String(describing: $0.connectionState),
                "activity": $0.activityState.rawValue,
            ]
        }
        return Self.json([
            "t": "roster",
            "projects": projects,
            "workspaces": workspaces,
            "sessions": sessions,
        ])
    }

    fileprivate func reportHook(path: String) async {
        guard let components = URLComponents(string: "http://127.0.0.1\(path)"),
              components.path == "/hook" else { return }
        let values = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        guard values["token"] == RelayPairingToken.current,
              let rawSession = values["session"],
              let sessionID = TerminalSessionID(uuidString: rawSession),
              let rawState = values["state"],
              let activity = TerminalSessionActivityState(rawValue: rawState) else { return }
        try? await service.reportSessionActivity(sessionID: sessionID, state: activity)
    }

    fileprivate func attach(_ sessionID: TerminalSessionID, to peer: SocketConnection) async {
        do {
            await detach(peer)
            let attachmentID = TerminalAttachmentID()
            let channel = try await service.openClientAttachment(
                sessionID: sessionID,
                clientID: peer.clientID,
                attachmentID: attachmentID
            )
            peer.attachmentID = channel.result.attachmentID
            peer.sessionID = sessionID
            peer.startOutputStream(channel.events)
        } catch {
            peer.sendText(Self.json([
                "t": "error",
                "message": String(describing: error),
            ]))
        }
    }

    fileprivate func create(
        workspaceID: WorkspaceID,
        command: String?,
        kind: TerminalSessionKind,
        title: String?,
        to peer: SocketConnection
    ) async {
        do {
            WebRelayServer.log("create begin")
            let session = try await service.createSession(
                workspaceID: workspaceID,
                launchCommand: command,
                kind: kind,
                title: title
            )
            WebRelayServer.log("create done \(session.id)")
            peer.sendText(Self.json([
                "t": "created",
                "session": session.id.description,
            ]))
        } catch {
            peer.sendText(Self.json([
                "t": "error",
                "message": String(describing: error),
            ]))
        }
    }

    fileprivate func input(_ data: Data, to peer: SocketConnection) async {
        guard let sessionID = peer.sessionID,
              let attachmentID = peer.attachmentID else { return }
        WebRelayServer.log("input begin \(sessionID) bytes=\(data.count)")
        do {
            try await service.sendClientInput(
                sessionID: sessionID,
                attachmentID: attachmentID,
                data: data
            )
            WebRelayServer.log("input done")
        } catch {
            WebRelayServer.log("input error \(error)")
            peer.sendText(Self.json([
                "t": "error",
                "message": String(describing: error),
            ]))
        }
    }

    fileprivate func resize(
        cols: Int,
        rows: Int,
        to peer: SocketConnection
    ) async {
        guard let sessionID = peer.sessionID,
              let attachmentID = peer.attachmentID,
              let size = TerminalSize(columns: cols, rows: rows) else { return }
        do {
            try await service.resizeClientAttachment(
                sessionID: sessionID,
                attachmentID: attachmentID,
                size: size
            )
        } catch {
            peer.sendText(Self.json([
                "t": "error",
                "message": String(describing: error),
            ]))
        }
    }

    fileprivate func detach(_ peer: SocketConnection) async {
        guard let sessionID = peer.sessionID,
              let attachmentID = peer.attachmentID else { return }
        peer.stopOutputStream()
        peer.sessionID = nil
        peer.attachmentID = nil
        await service.closeClientAttachment(
            sessionID: sessionID,
            attachmentID: attachmentID,
            reason: "web_detached"
        )
    }

    fileprivate func streamOutput(
        sessionID: TerminalSessionID,
        events: AsyncStream<HostSessionEvent>,
        to peer: SocketConnection
    ) async {
        WebRelayServer.log("stream start \(sessionID)")
        for await event in events {
            guard !Task.isCancelled else { return }
            switch event {
            case .binary(let frame):
                peer.sendBinary(frame.payload)
            case .control(.attached):
                peer.sendText(Self.json([
                    "t": "attached",
                    "session": sessionID.description,
                ]))
            case .control(.exit):
                peer.sendText(Self.json([
                    "t": "exited",
                    "session": sessionID.description,
                ]))
            case .control(.error(let error)):
                peer.sendText(Self.json([
                    "t": "error",
                    "message": error.message,
                ]))
            case .control:
                break
            }
        }
    }

    fileprivate func streamRoster(to peer: SocketConnection) async {
        var lastRoster: String?
        let stream = await service.snapshots()
        for await _ in stream {
            guard !Task.isCancelled else { return }
            let roster = await rosterJSON()
            guard roster != lastRoster else { continue }
            lastRoster = roster
            peer.sendText(roster)
        }
    }

    nonisolated static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: []
        ) else { return #"{"t":"error","message":"encoding"}"# }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum RelayPairingToken {
    static let key = "webRelay.token"

    static var current: String {
        if let token = UserDefaults.standard.string(forKey: key), !token.isEmpty {
            return token
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        UserDefaults.standard.set(token, forKey: key)
        return token
    }
}

private struct RelayEnvelope: Decodable {
    let t: String
    let token: String?
    let session: String?
    let workspace: String?
    let command: String?
    let kind: String?
    let title: String?
    let data: String?
    let cols: Int?
    let rows: Int?
}

@MainActor
private final class SocketConnection {
    let fd: Int32
    let clientID = ClientID()
    private let server: WebRelayServer
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var buffer = Data()
    private var outbound = Data()
    private var shutdownAfterWrite = false
    private var handshakeDone = false
    private var authenticated = false
    private var closed = false
    var attachmentID: TerminalAttachmentID?
    var sessionID: TerminalSessionID?
    private var outputTask: Task<Void, Never>?
    private var rosterTask: Task<Void, Never>?

    init(fd: Int32, server: WebRelayServer) {
        self.fd = fd
        self.server = server
    }

    func start() {
        WebRelayServer.log("conn start \(fd)")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler { [fd] in
            Darwin.close(fd)
        }
        source.resume()
        readSource = source
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.authenticated else { return }
            self.sendText(WebRelayServer.json([
                "t": "error",
                "message": "unauthorized",
            ]))
            self.close()
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(fd, &chunk, chunk.count)
        WebRelayServer.log("read \(fd) count=\(count)")
        if count > 0 {
            buffer.append(Data(chunk[0..<count]))
            processBuffer()
        } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            return
        } else {
            close()
        }
    }

    private func processBuffer() {
        WebRelayServer.log("process buffer count=\(buffer.count)")
        if !handshakeDone {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            WebRelayServer.log("header range found")
            let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                close()
                return
            }
            let lines = headerText.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ")
            guard parts.count >= 2 else {
                close()
                return
            }
            let method = String(parts[0]).uppercased()
            let path = String(parts[1])
            WebRelayServer.log("request \(method) \(path.split(separator: "?").first ?? "")")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                if pair.count == 2 {
                    headers[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                        pair[1].trimmingCharacters(in: .whitespaces)
                }
            }
            if method == "GET",
               headers["upgrade"]?.lowercased() == "websocket",
               path == "/ws" || path == "/",
               let key = headers["sec-websocket-key"] {
                let accept = Self.websocketAccept(key: key)
                let response =
                    "HTTP/1.1 101 Switching Protocols\r\n" +
                    "Upgrade: websocket\r\n" +
                    "Connection: Upgrade\r\n" +
                    "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
                writeAll(Data(response.utf8))
                handshakeDone = true
                processBuffer()
            } else if method == "GET", path == "/" || path == "/index.html" {
                sendHTTPPage()
            } else if method == "GET", path == "/manifest.webmanifest" {
                sendResource(name: "manifest", extension: "webmanifest", contentType: "application/manifest+json")
            } else if method == "GET", path == "/service-worker.js" {
                sendResource(name: "service-worker", extension: "js", contentType: "text/javascript; charset=utf-8")
            } else if method == "GET", path == "/icon.svg" {
                sendResource(name: "icon", extension: "svg", contentType: "image/svg+xml")
            } else if method == "GET", path.hasPrefix("/hook?") {
                Task { await server.reportHook(path: path) }
                sendHTTP(status: 204, body: "")
            } else {
                sendHTTP(status: 400, body: "Bad Request")
            }
            return
        }

        while let frame = Self.parseFrame(from: &buffer) {
            switch frame.opcode {
            case 0x1:
                if let text = String(data: frame.payload, encoding: .utf8) {
                    handleText(text)
                }
            case 0x2:
                Task { await server.input(frame.payload, to: self) }
            case 0x8:
                close()
                return
            case 0x9:
                sendFrame(opcode: 0xA, payload: frame.payload)
            default:
                break
            }
        }
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(RelayEnvelope.self, from: data) else {
            WebRelayServer.log("decode fail \(text)")
            return
        }
        WebRelayServer.log("handle \(envelope.t)")
        switch envelope.t {
        case "auth":
            guard envelope.token == RelayPairingToken.current else {
                sendText(WebRelayServer.json([
                    "t": "error",
                    "message": "unauthorized",
                ]))
                close()
                return
            }
            authenticated = true
            Task {
                let roster = await server.rosterJSON()
                self.sendText(roster)
                self.startRosterStream()
            }
        case "attach":
            guard authenticated,
                  let raw = envelope.session,
                  let uuid = UUID(uuidString: raw) else { return }
            let sessionID = TerminalSessionID(rawValue: uuid)
            Task { await server.attach(sessionID, to: self) }
        case "create":
            guard authenticated,
                  let rawWorkspace = envelope.workspace,
                  let uuid = UUID(uuidString: rawWorkspace) else { return }
            let workspaceID = WorkspaceID(rawValue: uuid)
            let kind = envelope.kind.flatMap(TerminalSessionKind.init(rawValue:)) ?? .shell
            Task { await server.create(
                workspaceID: workspaceID,
                command: envelope.command,
                kind: kind,
                title: envelope.title,
                to: self
            ) }
        case "input":
            guard authenticated,
                  let raw = envelope.data,
                  let payload = Data(base64Encoded: raw) else { return }
            Task { await server.input(payload, to: self) }
        case "resize":
            guard authenticated, let cols = envelope.cols, let rows = envelope.rows else { return }
            Task { await server.resize(cols: cols, rows: rows, to: self) }
        case "detach":
            Task { await server.detach(self) }
        default:
            break
        }
    }

    private func sendHTTPPage() {
        let data = Data((WebRelayServer.webPageHTML ?? "Burrow Web unavailable").utf8)
        let header =
            "HTTP/1.1 200 OK\r\n" +
            "X-Burrow: ok\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Cache-Control: no-store\r\n" +
            "Content-Length: \(data.count)\r\n" +
            "Connection: close\r\n\r\n"
        WebRelayServer.log("send http health")
        writeThenShutdown(header.data(using: .utf8)! + data)
    }

    private func sendResource(name: String, extension fileExtension: String, contentType: String) {
        guard let data = WebRelayServer.resourceData(named: name, extension: fileExtension) else {
            sendHTTP(status: 404, body: "Not Found")
            return
        }
        let header =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Cache-Control: no-cache\r\n" +
            "Content-Length: \(data.count)\r\n" +
            "Connection: close\r\n\r\n"
        writeThenShutdown(Data(header.utf8) + data)
    }

    private func sendHTTP(status: Int, body: String) {
        let data = Data(body.utf8)
        let header =
            "HTTP/1.1 \(status) \(status == 204 ? "No Content" : (status == 400 ? "Bad Request" : "Not Found"))\r\n" +
            "Content-Length: \(data.count)\r\n" +
            "Connection: close\r\n\r\n"
        writeThenShutdown(header.data(using: .utf8)! + data)
    }

    func startOutputStream(_ events: AsyncStream<HostSessionEvent>) {
        stopOutputStream()
        guard let sessionID else { return }
        outputTask = Task { [weak self] in
            guard let self else { return }
            await self.server.streamOutput(sessionID: sessionID, events: events, to: self)
        }
    }

    func stopOutputStream() {
        outputTask?.cancel()
        outputTask = nil
    }

    func startRosterStream() {
        rosterTask?.cancel()
        rosterTask = Task { [weak self] in
            guard let self else { return }
            await server.streamRoster(to: self)
        }
    }

    func sendText(_ text: String) {
        sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    func sendBinary(_ data: Data) {
        sendFrame(opcode: 0x2, payload: data)
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        var header = Data()
        header.append(0x80 | opcode)
        if payload.count < 126 {
            header.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            header.append(126)
            header.append(contentsOf: withUnsafeBytes(of: UInt16(payload.count).bigEndian) { Array($0) })
        } else {
            header.append(127)
            header.append(contentsOf: withUnsafeBytes(of: UInt64(payload.count).bigEndian) { Array($0) })
        }
        writeAll(header + payload)
    }

    private func writeThenShutdown(_ data: Data) {
        shutdownAfterWrite = true
        writeAll(data)
    }

    private func writeAll(_ data: Data) {
        guard !closed else { return }
        // A browser on a stalled mobile link must not retain unbounded PTY
        // output or block the desktop main actor.
        guard outbound.count + data.count <= 8 * 1024 * 1024 else {
            WebRelayServer.log("slow peer overflow \(fd)")
            close()
            return
        }
        outbound.append(data)
        drainWrites()
    }

    private func drainWrites() {
        while !outbound.isEmpty {
            let written = outbound.withUnsafeBytes { raw -> Int in
                Darwin.send(fd, raw.baseAddress, raw.count, 0)
            }
            if written > 0 {
                outbound.removeFirst(written)
                continue
            }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                ensureWriteSource()
                return
            }
            WebRelayServer.log("write errno=\(errno) remaining=\(outbound.count)")
            close()
            return
        }
        writeSource?.cancel()
        writeSource = nil
        if shutdownAfterWrite {
            shutdownAfterWrite = false
            shutdown(fd, SHUT_WR)
        }
    }

    private func ensureWriteSource() {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.drainWrites() }
        source.resume()
        writeSource = source
    }

    func close() {
        guard !closed else { return }
        closed = true
        let sessionID = sessionID
        let attachmentID = attachmentID
        stopOutputStream()
        self.sessionID = nil
        self.attachmentID = nil
        if let sessionID, let attachmentID {
            Task {
                await server.service.closeClientAttachment(
                    sessionID: sessionID,
                    attachmentID: attachmentID,
                    reason: "web_connection_closed"
                )
            }
        }
        rosterTask?.cancel()
        rosterTask = nil
        writeSource?.cancel()
        writeSource = nil
        outbound.removeAll(keepingCapacity: false)
        readSource?.cancel()
        readSource = nil
        server.drop(fd)
    }

    private static func websocketAccept(key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    private static func parseFrame(from buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        let opcode = first & 0x0F
        let masked = (second & 0x80) != 0
        var length = Int(second & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            length = Int(buffer[buffer.startIndex + offset]) << 8
                | Int(buffer[buffer.startIndex + offset + 1])
            offset += 2
        } else if length == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var value: UInt64 = 0
            for i in 0..<8 {
                value = (value << 8) | UInt64(buffer[buffer.startIndex + offset + i])
            }
            length = Int(value)
            offset += 8
        }
        var mask: [UInt8] = []
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            mask = Array(buffer.subdata(in: (buffer.startIndex + offset)..<(buffer.startIndex + offset + 4)))
            offset += 4
        }
        guard buffer.count >= offset + length else { return nil }
        var payload = Data(buffer.subdata(in: (buffer.startIndex + offset)..<(buffer.startIndex + offset + length)))
        if masked {
            for i in 0..<payload.count {
                payload[i] ^= mask[i % 4]
            }
        }
        buffer.removeFirst(offset + length)
        return (opcode, payload)
    }
}
