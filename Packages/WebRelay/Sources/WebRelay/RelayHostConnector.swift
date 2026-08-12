import Foundation

/// One outbound, multiplexed connection from the macOS Host to the deployable
/// control plane. The Relay never connects inbound to the Mac and never learns
/// the local pairing token: this adapter rewrites only the first Web auth frame
/// at the trusted Host edge before forwarding it to the loopback WebRelay.
public actor RelayHostConnector {
    public struct Configuration: Sendable, Hashable {
        public let relayURL: URL
        public let hostID: String
        public let hostName: String
        public let bootstrapToken: String
        public let localPairingToken: String

        public init(
            relayURL: URL,
            hostID: String,
            hostName: String,
            bootstrapToken: String,
            localPairingToken: String
        ) {
            self.relayURL = relayURL
            self.hostID = hostID
            self.hostName = hostName
            self.bootstrapToken = bootstrapToken
            self.localPairingToken = localPairingToken
        }
    }

    private static let headerSize = 22
    private static let maximumFrameBytes = 8 * 1024 * 1024
    private static let magic = Data("BRLY".utf8)

    private let configuration: Configuration
    private let session: URLSession
    private var relayTask: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var proxies: [ConnectionID: LocalWebProxy] = [:]

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.reconnectLoop()
        }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        relayTask?.cancel(with: .goingAway, reason: nil)
        relayTask = nil
        let current = proxies.values
        proxies.removeAll()
        for proxy in current {
            await proxy.stop()
        }
    }

    private func reconnectLoop() async {
        var retryNanoseconds: UInt64 = 500_000_000
        while !Task.isCancelled {
            do {
                try await connectOnce()
                retryNanoseconds = 500_000_000
            } catch is CancellationError {
                return
            } catch {
                relayTask?.cancel(with: .abnormalClosure, reason: nil)
                relayTask = nil
                let current = proxies.values
                proxies.removeAll()
                for proxy in current { await proxy.stop() }
                try? await Task.sleep(nanoseconds: retryNanoseconds)
                retryNanoseconds = min(retryNanoseconds * 2, 15_000_000_000)
            }
        }
    }

    private func connectOnce() async throws {
        guard var components = URLComponents(
            url: configuration.relayURL,
            resolvingAgainstBaseURL: false
        ) else { throw RelayHostConnectorError.invalidRelayURL }
        let usesTLS = components.scheme == "https" || components.scheme == "wss"
        components.scheme = usesTLS ? "wss" : "ws"
        components.path = "/v1/host/connect"
        components.queryItems = [
            URLQueryItem(name: "host_id", value: configuration.hostID),
            URLQueryItem(name: "name", value: configuration.hostName),
        ]
        guard let url = components.url else { throw RelayHostConnectorError.invalidRelayURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.bootstrapToken)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        relayTask = task
        task.resume()
        while !Task.isCancelled {
            let message = try await task.receive()
            guard case .data(let data) = message,
                  data.count <= Self.maximumFrameBytes + Self.headerSize,
                  let frame = Self.decode(data) else {
                throw RelayHostConnectorError.invalidRelayFrame
            }
            try await handle(frame)
        }
        throw CancellationError()
    }

    private func handle(_ frame: RelayFrame) async throws {
        switch frame.kind {
        case .open:
            if let old = proxies.removeValue(forKey: frame.connectionID) { await old.stop() }
            let proxy = LocalWebProxy(
                connectionID: frame.connectionID,
                localPairingToken: configuration.localPairingToken,
                sendToRelay: { [weak self] frame in try await self?.send(frame) }
            )
            proxies[frame.connectionID] = proxy
            await proxy.start()
        case .close:
            if let proxy = proxies.removeValue(forKey: frame.connectionID) { await proxy.stop() }
        case .text, .binary:
            guard let proxy = proxies[frame.connectionID] else { return }
            try await proxy.forward(frame)
        }
    }

    private func send(_ frame: RelayFrame) async throws {
        guard let relayTask else { throw RelayHostConnectorError.disconnected }
        try await relayTask.send(.data(Self.encode(frame)))
    }

    enum FrameKind: UInt8, Sendable {
        case open = 1
        case close = 2
        case text = 3
        case binary = 4
    }

    struct ConnectionID: Hashable, Sendable {
        let bytes: Data
    }

    struct RelayFrame: Sendable {
        let kind: FrameKind
        let connectionID: ConnectionID
        let payload: Data
    }

    static func encode(_ frame: RelayFrame) -> Data {
        var data = magic
        data.append(1)
        data.append(frame.kind.rawValue)
        data.append(frame.connectionID.bytes)
        data.append(frame.payload)
        return data
    }

    static func decode(_ data: Data) -> RelayFrame? {
        guard data.count >= headerSize,
              data.prefix(4) == magic,
              data[data.startIndex + 4] == 1,
              let kind = FrameKind(rawValue: data[data.startIndex + 5]) else { return nil }
        return RelayFrame(
            kind: kind,
            connectionID: ConnectionID(bytes: data.subdata(in: 6..<22)),
            payload: data.subdata(in: 22..<data.count)
        )
    }

    static func rewrittenAuthPayload(_ payload: Data, localPairingToken: String) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["t"] as? String == "auth" else { return nil }
        object["token"] = localPairingToken
        return try? JSONSerialization.data(withJSONObject: object)
    }
}

private actor LocalWebProxy {
    typealias RelayFrame = RelayHostConnector.RelayFrame
    typealias ConnectionID = RelayHostConnector.ConnectionID

    private let connectionID: ConnectionID
    private let localPairingToken: String
    private let sendToRelay: @Sendable (RelayFrame) async throws -> Void
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var didRewriteAuth = false

    init(
        connectionID: ConnectionID,
        localPairingToken: String,
        sendToRelay: @escaping @Sendable (RelayFrame) async throws -> Void
    ) {
        self.connectionID = connectionID
        self.localPairingToken = localPairingToken
        self.sendToRelay = sendToRelay
    }

    func start() {
        guard task == nil, let url = URL(string: "ws://127.0.0.1:\(WebRelayServer.defaultPort)/ws") else { return }
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func forward(_ frame: RelayFrame) async throws {
        guard let task else { throw RelayHostConnectorError.disconnected }
        switch frame.kind {
        case .text:
            var text = String(decoding: frame.payload, as: UTF8.self)
            if !didRewriteAuth,
               let data = RelayHostConnector.rewrittenAuthPayload(
                frame.payload,
                localPairingToken: localPairingToken
               ) {
                text = String(decoding: data, as: UTF8.self)
                didRewriteAuth = true
            }
            try await task.send(.string(text))
        case .binary:
            try await task.send(.data(frame.payload))
        case .open, .close:
            break
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                switch try await socket.receive() {
                case .string(let text):
                    try await sendToRelay(RelayFrame(
                        kind: .text,
                        connectionID: connectionID,
                        payload: Data(text.utf8)
                    ))
                case .data(let data):
                    try await sendToRelay(RelayFrame(
                        kind: .binary,
                        connectionID: connectionID,
                        payload: data
                    ))
                @unknown default:
                    break
                }
            }
        } catch {
            try? await sendToRelay(RelayFrame(kind: .close, connectionID: connectionID, payload: Data()))
        }
    }
}

public enum RelayHostConnectorError: Error, Sendable {
    case invalidRelayURL
    case invalidRelayFrame
    case disconnected
}
