import WarrenDomain
import WarrenHost
import WarrenLocalTransport
import WarrenStateStore
import Foundation

extension WarrenApplicationService {
    internal func resolveLocalHost(in candidate: inout PersistedHostState) -> (WarrenDomain.Host, Bool) {
        if let index = candidate.hosts.firstIndex(where: { $0.id == WarrenApplicationDefaults.localHost.id }) {
            var local = candidate.hosts[index]
            let name = local.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let original = local
            if name.isEmpty {
                local.name = hostName
                candidate.hosts[index] = local
            }
            return (local, local != original)
        }

        // A state file created by the first prototype may contain one local
        // Host with a generated ID. Keep that ID so projects remain linked;
        // the persisted ID is stable after this migration.
        if let index = candidate.hosts.indices.first {
            var existing = candidate.hosts[index]
            if existing.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.name = hostName
                candidate.hosts[index] = existing
                return (existing, true)
            }
            return (existing, false)
        }

        let created = WarrenApplicationDefaults.localHost
        candidate.hosts = [WarrenDomain.Host(id: created.id, name: hostName)]
        return (candidate.hosts[0], true)
    }

    internal func startEventLoop() {
        guard eventLoopTask == nil else { return }
        let stream = transport.events()
        eventLoopTask = Task { [weak self, stream] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    await self?.consumeTransportEvent(event)
                }
            } catch {
                await self?.transportDidEnd(error)
            }
        }
    }

    internal func startRuntimeLifecycleLoop() async {
        guard runtimeLifecycleTask == nil else { return }
        let stream = await coordinator.runtimeLifecycleEvents()
        runtimeLifecycleTask = Task { [weak self, stream] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                switch event {
                case .exited(let sessionID, _):
                    await self?.markSessionEnded(sessionID: sessionID)
                    await self?.publish()
                }
            }
        }
    }

    internal func transportDidEnd(_ error: Error) async {
        guard lifecycle == .ready || lifecycle == .starting else { return }
        eventLoopTask = nil
        if case InProcessHostTransportError.eventBufferOverflow = error {
            let oldTransport = transport
            await oldTransport.close()
            transport = InProcessHostTransport(coordinator: coordinator)
            startEventLoop()
            let reconnects = connections.map { (sessionID: $0.key, attachmentID: $0.value.attachmentID, store: $0.value.store) }
            for reconnect in reconnects {
                let snapshot = await reconnect.store.snapshot()
                guard let attachmentID = reconnect.attachmentID else { continue }
                do {
                    _ = try await attachInternal(
                        sessionID: reconnect.sessionID,
                        recoveryAnchor: snapshot.recoveryAnchor,
                        attachmentID: attachmentID,
                        requireReady: false
                    )
                } catch {
                    report(error.asApplicationError, id: "session.\(reconnect.sessionID).reconnect")
                }
            }
            await publish()
            return
        }
        lifecycle = .failed
        let appError = WarrenApplicationError.transport(String(describing: error))
        report(appError, id: "transport.ended")
        await publish()
    }

    internal func resolveAllWaiters(
        with result: Result<Void, WarrenApplicationError>
    ) {
        for waiter in attachmentWaiters.values {
            let mapped: Result<TerminalAttachmentID, WarrenApplicationError> = result.flatMap {
                .failure(.transport("The application service was closed."))
            }
            waiter.continuation.yield(mapped)
            waiter.continuation.finish()
        }
        attachmentWaiters.removeAll()
        for waiter in controlWaiters.values {
            waiter.continuation.yield(result)
            waiter.continuation.finish()
        }
        controlWaiters.removeAll()
    }
}
