import Foundation
import XCTest
import BurrowApplication
import BurrowDomain
import BurrowHost
import BurrowProtocol
import BurrowStateStore

final class BurrowApplicationTests: XCTestCase {
    func testFirstBootstrapCreatesStableLocalHost() async throws {
        let service = makeService()
        try await service.start()

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .ready)
        XCTAssertEqual(snapshot.host.id, BurrowApplicationDefaults.localHost.id)
        XCTAssertEqual(snapshot.host.name, "Local Mac")
        let persisted = await service.persistedState()
        XCTAssertEqual(persisted.hosts.count, 1)
    }

    func testFolderIsNormalizedDeduplicatedAndSavedWithRootWorkspace() async throws {
        let repository = InMemoryHostStateRepository()
        let service = makeService(repository: repository)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let project = try await service.addProject(path: folder.path + "/")
        let state = await service.persistedState()
        XCTAssertEqual(state.projects, [project])
        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.workspaces[0].projectID, project.id)
        XCTAssertEqual(state.workspaces[0].path, folder.resolvingSymlinksInPath().path)

        do {
            _ = try await service.addProject(folder: folder)
            XCTFail("Expected duplicate project")
        } catch let error as BurrowApplicationError {
            guard case .projectAlreadyExists = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let persisted = await service.persistedState()
        XCTAssertEqual(persisted.projects.count, 1)
    }

    func testWorkspaceQueriesExposeTypedBoundaries() async throws {
        let service = makeService()
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let snapshot = await service.snapshot()
        let workspace = try XCTUnwrap(snapshot.workspaces.first { $0.projectID == project.id })

        let queriedWorkspace = try await service.workspace(id: workspace.id)
        let queriedWorkspaces = try await service.workspaces(projectID: project.id)
        XCTAssertEqual(queriedWorkspace, workspace)
        XCTAssertEqual(queriedWorkspaces, [workspace])

        do {
            _ = try await service.workspace(id: WorkspaceID())
            XCTFail("Expected missing workspace error")
        } catch let error as BurrowApplicationError {
            guard case .workspaceNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            _ = try await service.workspaces(projectID: ProjectID())
            XCTFail("Expected missing project error")
        } catch let error as BurrowApplicationError {
            guard case .projectNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCreatePersistsRuntimeDescriptorImmediately() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let service = makeService(repository: repository, runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let initialSnapshot = await service.snapshot()
        let workspace = try XCTUnwrap(initialSnapshot.workspaces.first {
            $0.projectID == project.id
        })

        let session = try await service.createSession(workspaceID: workspace.id)
        let createdSnapshot = await service.snapshot()
        XCTAssertEqual(
            createdSnapshot.session(id: session.id)?.tabID,
            "session-\(session.id.description)"
        )
        let persistedState = await service.persistedState()
        let persisted = try XCTUnwrap(persistedState.terminalSessions.first {
            $0.id == session.id
        })
        let runtimeRecord = await runtime.record(session.id)
        let descriptor = try XCTUnwrap(runtimeRecord?.descriptor)
        XCTAssertEqual(persisted.runtimeAdoptionDescriptor, RuntimeAdoptionDescriptor(descriptor))
        let afterCreate = await service.snapshot()
        XCTAssertEqual(afterCreate.sessions.map(\.id), [session.id])
    }

    func testAddTabAttachesAndAcquiresControl() async throws {
        let runtime = RestorableRuntime()
        let service = makeService(runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let projectSnapshot = await service.snapshot()
        let workspace = try XCTUnwrap(
            projectSnapshot.workspaces.first { $0.projectID == project.id }
        )

        let tabID = try await service.addTab(workspaceID: workspace.id)
        let tabSnapshot = await service.snapshot()
        let session = try XCTUnwrap(tabSnapshot.sessions.first { $0.tabID == tabID })

        XCTAssertNotNil(session.attachmentID)
        XCTAssertEqual(session.controllerAttachmentID, session.attachmentID)
        XCTAssertNotNil(session.controlLeaseID)
    }

    func testCreateSessionPersistsKindTitleAndWritesLaunchCommand() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let service = makeService(repository: repository, runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let snapshot = await service.snapshot()
        let workspace = try XCTUnwrap(snapshot.workspaces.first { $0.projectID == project.id })

        let session = try await service.createSession(
            workspaceID: workspace.id,
            launchCommand: "codex --dangerously-bypass-approvals-and-sandbox",
            kind: .codex,
            title: "Codex"
        )
        let record = await runtime.record(session.id)
        let runtimeRecord = try XCTUnwrap(record)
        XCTAssertEqual(
            runtimeRecord.writes.first,
            Data("codex --dangerously-bypass-approvals-and-sandbox\r".utf8)
        )

        let persisted = await service.persistedState()
        let durable = try XCTUnwrap(persisted.terminalSessions.first { $0.id == session.id })
        XCTAssertEqual(durable.kind, .codex)
        XCTAssertEqual(durable.title, "Codex")

        let projected = await service.snapshot()
        let projectedSession = try XCTUnwrap(projected.session(id: session.id))
        XCTAssertEqual(projectedSession.kind, .codex)
        XCTAssertEqual(projectedSession.title, "Codex")
        XCTAssertEqual(
            projected.tabs.first { $0.sessionID == session.id }?.kind,
            .codex
        )
    }

    func testRestoreRecreatesMissingRuntimeAndAttaches() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let host = BurrowApplicationDefaults.localHost
        let project = Project(hostID: host.id, name: "den", rootPath: folder.path)
        let workspace = Workspace(
            projectID: project.id,
            name: "main",
            path: folder.path
        )
        let sessionID = TerminalSessionID()
        let size = try XCTUnwrap(TerminalSize(columns: 120, rows: 40))
        let persisted = PersistedTerminalSession(
            id: sessionID,
            workspaceID: workspace.id,
            workingDirectory: folder.path,
            terminalSize: size,
            runtimeAdoptionDescriptor: RuntimeAdoptionDescriptor(
                runtime: "test-runtime",
                identifier: sessionID.description,
                metadata: ["workingDirectory": folder.path]
            )
        )
        let state = PersistedHostState(
            hosts: [host],
            projects: [project],
            workspaces: [workspace],
            terminalSessions: [persisted]
        )
        try await repository.save(state)

        let existsBefore = await runtime.exists(sessionID: sessionID)
        XCTAssertFalse(existsBefore)
        let service = BurrowApplicationService(repository: repository, runtime: runtime)
        try await service.start()

        let snapshot = await service.snapshot()
        let session = try XCTUnwrap(snapshot.session(id: sessionID))
        XCTAssertEqual(session.connectionState, .attached)
        let existsAfter = await runtime.exists(sessionID: sessionID)
        XCTAssertTrue(existsAfter)
    }

    func testStartupDoesNotRestoreOrRecreateHiddenSessions() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let host = BurrowApplicationDefaults.localHost
        let project = Project(hostID: host.id, name: "den", rootPath: folder.path)
        let workspace = Workspace(projectID: project.id, name: "main", path: folder.path)
        let sessionID = TerminalSessionID()
        let persisted = PersistedTerminalSession(
            id: sessionID,
            workspaceID: workspace.id,
            workingDirectory: folder.path,
            terminalSize: TerminalSessionCoordinator.defaultTerminalSize,
            runtimeAdoptionDescriptor: RuntimeAdoptionDescriptor(
                runtime: "test-runtime",
                identifier: sessionID.description,
                metadata: ["workingDirectory": folder.path]
            ),
            title: "Background CLI",
            isTabVisible: false
        )
        try await repository.save(PersistedHostState(
            hosts: [host],
            projects: [project],
            workspaces: [workspace],
            terminalSessions: [persisted]
        ))

        let service = BurrowApplicationService(repository: repository, runtime: runtime)
        try await service.start()

        let snapshot = await service.snapshot()
        let runtimeExists = await runtime.exists(sessionID: sessionID)
        XCTAssertEqual(snapshot.sessions.map(\.id), [sessionID])
        XCTAssertEqual(snapshot.session(id: sessionID)?.connectionState, .disconnected)
        XCTAssertTrue(snapshot.tabs.isEmpty)
        XCTAssertFalse(runtimeExists)
    }

    func testExplicitOpenLazilyRestoresHiddenSession() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let host = BurrowApplicationDefaults.localHost
        let project = Project(hostID: host.id, name: "den", rootPath: folder.path)
        let workspace = Workspace(projectID: project.id, name: "main", path: folder.path)
        let sessionID = TerminalSessionID()
        let persisted = PersistedTerminalSession(
            id: sessionID,
            workspaceID: workspace.id,
            workingDirectory: folder.path,
            terminalSize: TerminalSessionCoordinator.defaultTerminalSize,
            runtimeAdoptionDescriptor: RuntimeAdoptionDescriptor(
                runtime: "test-runtime",
                identifier: sessionID.description,
                metadata: ["workingDirectory": folder.path]
            ),
            title: "Background CLI",
            isTabVisible: false
        )
        try await repository.save(PersistedHostState(
            hosts: [host],
            projects: [project],
            workspaces: [workspace],
            terminalSessions: [persisted]
        ))

        let service = BurrowApplicationService(repository: repository, runtime: runtime)
        try await service.start()
        let tabID = try await service.openSession(sessionID: sessionID)

        let snapshot = await service.snapshot()
        let runtimeExists = await runtime.exists(sessionID: sessionID)
        XCTAssertEqual(snapshot.tabs.map(\.id), [tabID])
        XCTAssertEqual(snapshot.sessions.map(\.id), [sessionID])
        XCTAssertTrue(runtimeExists)
        XCTAssertNotNil(snapshot.session(id: sessionID)?.attachmentID)
    }

    func testNewTabsStayBoundToRequestedWorkspaceAndKeepCreationOrder() async throws {
        let runtime = RestorableRuntime()
        let service = makeService(runtime: runtime)
        try await service.start()
        let firstFolder = try temporaryFolder()
        let secondFolder = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: firstFolder)
            try? FileManager.default.removeItem(at: secondFolder)
        }

        let firstProject = try await service.addProject(folder: firstFolder)
        let secondProject = try await service.addProject(folder: secondFolder)
        let beforeTabs = await service.snapshot()
        let firstWorkspace = try XCTUnwrap(
            beforeTabs.workspaces.first { $0.projectID == firstProject.id }
        )
        let secondWorkspace = try XCTUnwrap(
            beforeTabs.workspaces.first { $0.projectID == secondProject.id }
        )

        let firstTabID = try await service.addTab(workspaceID: firstWorkspace.id)
        let secondTabID = try await service.addTab(workspaceID: secondWorkspace.id)
        let afterTabs = await service.snapshot()
        let first = try XCTUnwrap(afterTabs.sessions.first { $0.tabID == firstTabID })
        let second = try XCTUnwrap(afterTabs.sessions.first { $0.tabID == secondTabID })
        let firstWorkingDirectory = await runtime.record(first.id)?.descriptor.metadata["workingDirectory"]
        let secondWorkingDirectory = await runtime.record(second.id)?.descriptor.metadata["workingDirectory"]

        XCTAssertEqual(afterTabs.tabs.map(\.id), [
            firstTabID,
            secondTabID,
        ])
        XCTAssertEqual(afterTabs.sessions.map(\.workspaceID), [
            firstWorkspace.id,
            secondWorkspace.id,
        ])
        XCTAssertEqual(
            afterTabs.tabs(in: secondWorkspace.id).compactMap(\.sessionID),
            [second.id]
        )
        XCTAssertEqual(
            firstWorkingDirectory,
            firstFolder.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            secondWorkingDirectory,
            secondFolder.resolvingSymlinksInPath().path
        )
    }

    func testClosingTabsHidesClientTabsButKeepsRuntimeAndDurableSessions() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let service = makeService(repository: repository, runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let initial = await service.snapshot()
        let workspace = try XCTUnwrap(initial.workspaces.first { $0.projectID == project.id })

        let firstTabID = try await service.addTab(workspaceID: workspace.id)
        let secondTabID = try await service.addTab(workspaceID: workspace.id)
        let thirdTabID = try await service.addTab(workspaceID: workspace.id)
        let created = await service.snapshot()
        let sessions = created.sessions.map(\.id)
        let first = try XCTUnwrap(created.sessions.first { $0.tabID == firstTabID })
        let second = try XCTUnwrap(created.sessions.first { $0.tabID == secondTabID })
        let third = try XCTUnwrap(created.sessions.first { $0.tabID == thirdTabID })

        await service.closeTabs(except: second.tabID)
        let afterOthers = await service.snapshot()
        XCTAssertEqual(afterOthers.tabs.map(\.id), [secondTabID])
        XCTAssertEqual(afterOthers.sessions.map(\.id), sessions)
        XCTAssertEqual(
            afterOthers.session(id: first.id)?.connectionState,
            .disconnected
        )

        let durableAfterOthers = await service.persistedState()
        for sessionID in sessions {
            let runtimeAlive = await runtime.exists(sessionID: sessionID)
            XCTAssertTrue(runtimeAlive)
            XCTAssertNotNil(durableAfterOthers.terminalSessions.first { $0.id == sessionID })
        }

        // A stale close event is an idempotent no-op for the composition root.
        try await service.closeTabIfPresent(tabID: first.tabID)
        await service.closeTabs()
        let afterAll = await service.snapshot()
        XCTAssertTrue(afterAll.tabs.isEmpty)
        XCTAssertEqual(afterAll.sessions.map(\.id), sessions)
        let firstAlive = await runtime.exists(sessionID: first.id)
        let secondAlive = await runtime.exists(sessionID: second.id)
        let thirdAlive = await runtime.exists(sessionID: third.id)
        XCTAssertTrue(firstAlive)
        XCTAssertTrue(secondAlive)
        XCTAssertTrue(thirdAlive)
        let durable = await service.persistedState()
        XCTAssertEqual(
            Set(durable.terminalSessions.map(\.id)),
            Set(sessions)
        )

        let reopenedTabID = try await service.openSession(sessionID: first.id)
        let reopened = await service.snapshot()
        XCTAssertEqual(reopenedTabID, firstTabID)
        XCTAssertEqual(reopened.tabs.map(\.id), [firstTabID])
        XCTAssertEqual(reopened.session(id: first.id)?.connectionState, .attached)
    }

    func testClosingWorkspaceTabsDoesNotCloseAnotherWorkspace() async throws {
        let runtime = RestorableRuntime()
        let service = makeService(runtime: runtime)
        try await service.start()
        let firstFolder = try temporaryFolder()
        let secondFolder = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: firstFolder)
            try? FileManager.default.removeItem(at: secondFolder)
        }
        let firstProject = try await service.addProject(folder: firstFolder)
        let secondProject = try await service.addProject(folder: secondFolder)
        let before = await service.snapshot()
        let firstWorkspace = try XCTUnwrap(before.workspaces.first { $0.projectID == firstProject.id })
        let secondWorkspace = try XCTUnwrap(before.workspaces.first { $0.projectID == secondProject.id })
        _ = try await service.addTab(workspaceID: firstWorkspace.id)
        let secondTabID = try await service.addTab(workspaceID: secondWorkspace.id)

        await service.closeTabs(in: firstWorkspace.id)

        let after = await service.snapshot()
        XCTAssertTrue(after.tabs(in: firstWorkspace.id).isEmpty)
        XCTAssertEqual(after.tabs(in: secondWorkspace.id).map(\.id), [secondTabID])
    }

    func testAttachControlInputResizeAndOutputUseOneTransportProjection() async throws {
        let runtime = RestorableRuntime()
        let service = makeService(runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let initialSnapshot = await service.snapshot()
        let workspace = try XCTUnwrap(initialSnapshot.workspaces.first {
            $0.projectID == project.id
        })
        let session = try await service.createSession(workspaceID: workspace.id)
        let attachment = try await service.attach(sessionID: session.id)
        try await service.requestControl(sessionID: session.id, attachmentID: attachment)
        try await service.sendInput(
            sessionID: session.id,
            attachmentID: attachment,
            data: Data("echo burrow\n".utf8)
        )
        let size = try XCTUnwrap(TerminalSize(columns: 120, rows: 40))
        try await service.resize(sessionID: session.id, attachmentID: attachment, size: size)

        let runtimeRecord = await runtime.record(session.id)
        let input = try XCTUnwrap(runtimeRecord?.writes.last)
        XCTAssertEqual(input, Data("echo burrow\n".utf8))
        XCTAssertEqual(runtimeRecord?.resizes.last, size)
        let resizedSnapshot = await service.snapshot()
        XCTAssertEqual(resizedSnapshot.session(id: session.id)?.terminalSize, size)
        let resizedState = await service.persistedState()
        XCTAssertEqual(
            resizedState.terminalSessions.first { $0.id == session.id }?.terminalSize,
            size
        )

        let stream = await service.snapshots()
        let marker = Data("DEN_OUTPUT".utf8)
        try await runtime.emitOutput(sessionID: session.id, data: marker)
        let snapshot = try await nextSnapshot(from: stream) { snapshot in
            snapshot.session(id: session.id)?.output?.upperSequence == UInt64(marker.count)
        }
        XCTAssertEqual(snapshot.session(id: session.id)?.output?.frames.last?.payload, marker)
        let persisted = await service.persistedState()
        XCTAssertEqual(
            persisted.terminalSessions.first { $0.id == session.id }?.sequence,
            UInt64(marker.count)
        )
    }

    func testResizeRecalibratesRuntimeWhenPersistedSizeAlreadyMatches() async throws {
        let runtime = RestorableRuntime()
        let service = makeService(runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let snapshot = await service.snapshot()
        let workspace = try XCTUnwrap(snapshot.workspaces.first {
            $0.projectID == project.id
        })
        let session = try await service.createSession(workspaceID: workspace.id)
        let attachment = try await service.attach(sessionID: session.id)
        let size = try XCTUnwrap(TerminalSize(columns: 123, rows: 40))

        try await service.resize(sessionID: session.id, attachmentID: attachment, size: size)
        try await service.resize(sessionID: session.id, attachmentID: attachment, size: size)

        let runtimeRecord = await runtime.record(session.id)
        XCTAssertEqual(runtimeRecord?.resizes, [size, size])
        let durable = await service.persistedState()
        XCTAssertEqual(
            durable.terminalSessions.first { $0.id == session.id }?.terminalSize,
            size
        )
    }

    func testDetachLeavesRuntimeAndPersistedSessionAlive() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let service = makeService(repository: repository, runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let snapshot = await service.snapshot()
        let workspace = try XCTUnwrap(snapshot.workspaces.first {
            $0.projectID == project.id
        })
        let session = try await service.createSession(workspaceID: workspace.id)
        let attachment = try await service.attach(sessionID: session.id)
        try await service.detach(sessionID: session.id, attachmentID: attachment)

        let runtimeAlive = await runtime.exists(sessionID: session.id)
        XCTAssertTrue(runtimeAlive)
        let persisted = await service.persistedState()
        XCTAssertNotNil(persisted.terminalSessions.first { $0.id == session.id })
        let afterDetach = await service.snapshot()
        XCTAssertEqual(afterDetach.session(id: session.id)?.connectionState, .disconnected)
    }

    func testOutputCursorDoesNotRollBackWhenResizeSaveSuspends() async throws {
        let runtime = RestorableRuntime()
        let repository = ControlledHostStateRepository()
        let service = makeService(repository: repository, runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let projectSnapshot = await service.snapshot()
        let workspace = try XCTUnwrap(
            projectSnapshot.workspaces.first { $0.projectID == project.id }
        )
        let session = try await service.createSession(workspaceID: workspace.id)
        let attachment = try await service.attach(sessionID: session.id)
        try await service.requestControl(sessionID: session.id, attachmentID: attachment)

        let blocked = await repository.blockNextSave()
        let size = try XCTUnwrap(TerminalSize(columns: 132, rows: 44))
        let resizeTask = Task {
            try await service.resize(sessionID: session.id, attachmentID: attachment, size: size)
        }
        for await _ in blocked { break }

        let marker = Data("cursor-during-save".utf8)
        let outputStream = await service.snapshots()
        try await runtime.emitOutput(sessionID: session.id, data: marker)
        _ = try await nextSnapshot(from: outputStream) {
            $0.session(id: session.id)?.output?.upperSequence == UInt64(marker.count)
        }
        await repository.resumeBlockedSave()
        try await resizeTask.value

        let inMemory = await service.persistedState()
        let current = try XCTUnwrap(inMemory.terminalSessions.first { $0.id == session.id })
        XCTAssertEqual(current.terminalSize, size)
        XCTAssertEqual(current.sequence, UInt64(marker.count))

        await service.shutdown()
        let durable = try await repository.load()
        XCTAssertEqual(
            durable.terminalSessions.first { $0.id == session.id }?.sequence,
            UInt64(marker.count)
        )
    }

    func testBurstOutputPublishesLastFrameAndShutdownFlushesCursor() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let service = makeService(repository: repository, runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let projectSnapshot = await service.snapshot()
        let workspace = try XCTUnwrap(
            projectSnapshot.workspaces.first { $0.projectID == project.id }
        )
        let session = try await service.createSession(workspaceID: workspace.id)
        let attachment = try await service.attach(sessionID: session.id)
        try await service.requestControl(sessionID: session.id, attachmentID: attachment)

        let chunks = [Data("one".utf8), Data("-two".utf8), Data("-last".utf8)]
        let expectedLength = chunks.reduce(0) { $0 + $1.count }
        let stream = await service.snapshots()
        for chunk in chunks {
            try await runtime.emitOutput(sessionID: session.id, data: chunk)
        }
        let published = try await nextSnapshot(from: stream) {
            $0.session(id: session.id)?.output?.upperSequence == UInt64(expectedLength)
        }
        XCTAssertEqual(published.session(id: session.id)?.output?.frames.last?.payload, chunks.last)

        await service.shutdown()
        let durable = try await repository.load()
        XCTAssertEqual(
            durable.terminalSessions.first { $0.id == session.id }?.sequence,
            UInt64(expectedLength)
        )
    }

    func testNewServiceAdoptsExistingRuntimeAndRestoresProjection() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let first = makeService(repository: repository, runtime: runtime)
        try await first.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await first.addProject(folder: folder)
        let firstSnapshot = await first.snapshot()
        let workspace = try XCTUnwrap(firstSnapshot.workspaces.first {
            $0.projectID == project.id
        })
        let created = try await first.createSession(workspaceID: workspace.id)
        let marker = Data("before-restart".utf8)
        let firstAttachment = try await first.attach(sessionID: created.id)
        try await first.requestControl(sessionID: created.id, attachmentID: firstAttachment)
        let stream = await first.snapshots()
        try await runtime.emitOutput(sessionID: created.id, data: marker)
        _ = try await nextSnapshot(from: stream) { $0.session(id: created.id)?.output?.upperSequence == UInt64(marker.count) }
        await first.shutdown()

        let second = makeService(repository: repository, runtime: runtime)
        try await second.start()
        let restored = try await nextSnapshot(from: await second.snapshots()) {
            guard let session = $0.session(id: created.id) else { return false }
            return session.connectionState == .attached &&
                session.recoveryAnchor?.sequence == UInt64(marker.count) &&
                session.output?.frames.contains { $0.payload == marker } == true
        }
        XCTAssertEqual(restored.sessions.map(\.id), [created.id])
        XCTAssertEqual(restored.session(id: created.id)?.recoveryAnchor?.sequence, UInt64(marker.count))
        XCTAssertEqual(restored.session(id: created.id)?.recoveryAnchor?.epoch, 1)
        let adoptionCount = await runtime.adoptCount(for: created.id)
        let adoptionOffset = await runtime.adoptOffset(for: created.id)
        XCTAssertEqual(adoptionCount, 1)
        XCTAssertEqual(adoptionOffset, 0)
        XCTAssertEqual(restored.session(id: created.id)?.output?.frames.last?.payload, marker)
    }

    private func makeService(
        repository: any HostStateRepository = InMemoryHostStateRepository(),
        runtime: any TerminalRuntime = RestorableRuntime()
    ) -> BurrowApplicationService {
        BurrowApplicationService(repository: repository, runtime: runtime)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-application-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func nextSnapshot(
        from stream: AsyncStream<BurrowApplicationSnapshot>,
        matching predicate: @escaping @Sendable (BurrowApplicationSnapshot) -> Bool
    ) async throws -> BurrowApplicationSnapshot {
        try await withThrowingTaskGroup(of: BurrowApplicationSnapshot.self) { group in
            group.addTask {
                for await snapshot in stream where predicate(snapshot) {
                    return snapshot
                }
                throw TestError.timeout
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw TestError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

private enum TestError: Error { case timeout }
