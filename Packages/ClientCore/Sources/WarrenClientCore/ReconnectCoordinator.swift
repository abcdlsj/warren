import WarrenDomain
import WarrenProtocol

/// Builds attach messages from a retained client projection. It does not own a
/// timer or global connectivity observer; app lifecycle code can call these
/// methods whenever foreground/network state changes.
public struct ReconnectCoordinator: Sendable {
    public let version: ProtocolVersion
    public let capabilities: ProtocolCapabilities

    public init(
        version: ProtocolVersion = .current,
        capabilities: ProtocolCapabilities = .core
    ) {
        self.version = version
        self.capabilities = capabilities
    }

    public func makeAttachRequest(from snapshot: ClientSessionSnapshot) -> AttachRequest {
        AttachRequest(
            version: version,
            sessionID: snapshot.sessionID,
            clientID: snapshot.clientID,
            capabilities: capabilities,
            attachmentID: snapshot.attachmentID,
            recoveryAnchor: snapshot.reanchorRequired ? nil : snapshot.recoveryAnchor
        )
    }

    public func makeAttachRequest(from store: ClientSessionStore) async -> AttachRequest {
        makeAttachRequest(from: await store.snapshot())
    }

    /// Sends the attach request and leaves receipt of `attached` to the normal
    /// transport event consumer. A failed send keeps the store's projection
    /// and anchor intact.
    @discardableResult
    public func reconnect(
        through transport: any HostTransport,
        store: ClientSessionStore
    ) async throws -> AttachRequest {
        await store.markConnecting()
        let request = await makeAttachRequest(from: store)
        do {
            try await transport.send(.attach(request))
        } catch {
            await store.markDisconnected()
            throw error
        }
        return request
    }

    public func markDisconnected(store: ClientSessionStore) async {
        await store.markDisconnected()
    }
}
