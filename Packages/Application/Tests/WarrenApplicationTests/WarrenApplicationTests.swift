import Foundation
import XCTest
import WarrenApplication
import WarrenDomain
import WarrenHost
import WarrenProtocol
import WarrenStateStore

final class WarrenApplicationTests: XCTestCase {
    func testRemoteAttachmentDoesNotReplaceDesktopAttachment() async throws {
        let runtime = RestorableRuntime()
        let service = makeService(runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let workspace = try await service.rootWorkspace(for: project.id)
        let tabID = try await service.addTab(workspaceID: workspace.id)
        let before = await service.snapshot()
        let session = try XCTUnwrap(before.sessions.first { $0.tabID == tabID })
        let desktopAttachmentID = try XCTUnwrap(session.attachmentID)
        let remoteAttachmentID = TerminalAttachmentID()

        let channel = try await service.openClientAttachment(
            sessionID: session.id,
            clientID: ClientID(),
            attachmentID: remoteAttachmentID
        )
        XCTAssertEqual(channel.result.attachmentID, remoteAttachmentID)
        let host = try await service.hostSessionSnapshot(sessionID: session.id)
        XCTAssertEqual(Set(host.attachments.map(\.id)), [desktopAttachmentID, remoteAttachmentID])
        let remoteSnapshot = await service.snapshot()
        XCTAssertEqual(remoteSnapshot.session(id: session.id)?.attachmentID, desktopAttachmentID)

        await service.closeClientAttachment(
            sessionID: session.id,
            attachmentID: remoteAttachmentID,
            reason: "test"
        )
        let detached = try await service.hostSessionSnapshot(sessionID: session.id)
        XCTAssertEqual(detached.attachments.map(\.id), [desktopAttachmentID])
    }

    func testAgentActivityIsOptionalAndTerminalEndClearsProjection() async throws {
        let runtime = RestorableRuntime()
        let service = makeService(runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let workspace = try await service.rootWorkspace(for: project.id)
        let session = try await service.createSession(
            workspaceID: workspace.id,
            kind: .claude,
            title: "Claude"
        )

        let initialSnapshot = await service.snapshot()
        XCTAssertNil(initialSnapshot.session(id: session.id)?.agentActivity)
        try await service.reportAgentActivity(
            sessionID: session.id,
            state: .waitingForInput
        )
        let waitingSnapshot = await service.snapshot()
        XCTAssertEqual(waitingSnapshot.session(id: session.id)?.agentActivity, .waitingForInput)
        try await service.terminateSession(sessionID: session.id)
        let exitedSnapshot = await service.snapshot()
        XCTAssertNil(exitedSnapshot.session(id: session.id)?.agentActivity)
    }
    func testSupersetImportPublishesResourcesWithoutCreatingSessions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WarrenApplicationImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try SQLiteHostStateRepository(
            databaseURL: directory.appendingPathComponent("state.sqlite3")
        )
        let runtime = InMemoryTerminalRuntime()
        let service = WarrenApplicationService(repository: repository, runtime: runtime)
        try await service.start()
        let preview = SupersetImportPreview(
            sourcePath: directory.appendingPathComponent("superset.db").path,
            schemaVersion: 45,
            projects: [
                SupersetImportProjectCandidate(
                    sourceProjectID: "source-project",
                    name: "Imported",
                    repositoryPath: "/repos/imported",
                    status: .ready,
                    workspaces: [
                        SupersetImportWorkspaceCandidate(
                            id: "source-workspace",
                            sourceWorkspaceID: "source-workspace",
                            sourceWorktreeID: nil,
                            sourceProjectID: "source-project",
                            name: "main",
                            path: "/repos/imported",
                            branch: "main",
                            kind: "main_checkout",
                            status: .ready
                        ),
                    ]
                ),
            ]
        )

        let result = try await service.commitSupersetImport(preview)
        let snapshot = await service.snapshot()

        XCTAssertEqual(result.importedProjectIDs.count, 1)
        XCTAssertEqual(result.importedWorkspaceIDs.count, 1)
        XCTAssertEqual(snapshot.projects.map(\.name), ["Imported"])
        XCTAssertEqual(snapshot.workspaces.map(\.name), ["main"])
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.windowLayout.workspaceViews.flatMap(\.tabs).isEmpty)
        let runtimeRecords = await runtime.allRecords()
        XCTAssertTrue(runtimeRecords.isEmpty)
    }

    func testFirstBootstrapCreatesStableLocalHost() async throws {
        let service = makeService()
        try await service.start()

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .ready)
        XCTAssertEqual(snapshot.host.id, WarrenApplicationDefaults.localHost.id)
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
        } catch let error as WarrenApplicationError {
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
        } catch let error as WarrenApplicationError {
            guard case .workspaceNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            _ = try await service.workspaces(projectID: ProjectID())
            XCTFail("Expected missing project error")
        } catch let error as WarrenApplicationError {
            guard case .projectNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCreateWorkspaceUsesGitAdapterAndRequestReceiptIsIdempotent() async throws {
        let repository = InMemoryHostStateRepository()
        let worktrees = WorktreeManagerSpy()
        let service = WarrenApplicationService(
            repository: repository,
            runtime: RestorableRuntime(),
            gitWorktreeManager: worktrees
        )
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let destination = folder.deletingLastPathComponent()
            .appendingPathComponent("warren-worktree-\(UUID().uuidString)")
        let request = WorkspaceCreationRequest(
            requestID: UUID(),
            branch: "feature/renderer",
            path: destination.path
        )

        let first = try await service.createWorkspace(projectID: project.id, request: request)
        let replay = try await service.createWorkspace(projectID: project.id, request: request)

        XCTAssertEqual(first, replay)
        XCTAssertEqual(first.branch, "feature/renderer")
        let calls = await worktrees.creations
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.repositoryPath, project.rootPath)
        XCTAssertEqual(calls.first?.worktreePath, destination.path)
        let persisted = await service.persistedState()
        XCTAssertEqual(persisted.workspaces.filter { $0.id == first.id }.count, 1)
        XCTAssertEqual(
            persisted.requestReceipts.filter { $0.requestID == request.requestID }.count,
            1
        )
        let finalSnapshot = await service.snapshot()
        XCTAssertEqual(finalSnapshot.windowLayout.activeWorkspaceID, first.id)
    }

    func testCreateWorkspaceDefaultsToWorktreeRootDirectory() async throws {
        let repository = InMemoryHostStateRepository()
        let worktrees = WorktreeManagerSpy()
        let root = try temporaryFolder().appendingPathComponent(".warren/worktrees")
        let service = WarrenApplicationService(
            repository: repository,
            runtime: RestorableRuntime(),
            gitWorktreeManager: worktrees,
            worktreeRootDirectory: root
        )
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)

        _ = try await service.createWorkspace(
            projectID: project.id,
            request: WorkspaceCreationRequest(branch: "feature/default")
        )

        let calls = await worktrees.creations
        XCTAssertEqual(calls.count, 1)
        let worktreePath = try XCTUnwrap(calls.first?.worktreePath)
        XCTAssertTrue(
            worktreePath.hasPrefix(root.path + "/"),
            "expected default worktree under \(root.path), got \(worktreePath)"
        )
    }

    func testDefaultWorktreeRootDirectoryUsesWarrenWorktrees() {
        let root = WarrenApplicationDefaults.worktreeRootDirectory()
        XCTAssertEqual(root.lastPathComponent, "worktrees")
        XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, ".warren")
    }

    func testLocalGitWorktreeManagerCreatesRealWorktree() async throws {
        let repository = try temporaryFolder()
        let worktree = repository.deletingLastPathComponent()
            .appendingPathComponent("warren-real-worktree-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: worktree)
            try? FileManager.default.removeItem(at: repository)
        }
        try runGit(["init", "-b", "main", repository.path])
        try Data("fixture\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        try runGit(["-C", repository.path, "add", "README.md"])
        try runGit([
            "-C", repository.path,
            "-c", "user.name=Warren Test",
            "-c", "user.email=warren@example.invalid",
            "commit", "-m", "fixture",
        ])
        let manager = LocalGitWorktreeManager()
        let request = GitWorktreeCreation(
            repositoryPath: repository.path,
            worktreePath: worktree.path,
            branch: "feature/real-worktree"
        )

        try await manager.create(request)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertEqual(
            try gitOutput(["-C", worktree.path, "branch", "--show-current"]),
            "feature/real-worktree"
        )
        try await manager.remove(request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
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
        XCTAssertNil(createdSnapshot.session(id: session.id)?.tabID)
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
        XCTAssertTrue(runtimeRecord.writes.isEmpty)
        XCTAssertEqual(
            runtimeRecord.descriptor.metadata["launchSpec"],
            "command(\"codex --dangerously-bypass-approvals-and-sandbox\")"
        )

        let persisted = await service.persistedState()
        let durable = try XCTUnwrap(persisted.terminalSessions.first { $0.id == session.id })
        XCTAssertEqual(durable.kind, .codex)
        XCTAssertEqual(durable.title, "Codex")

        let projected = await service.snapshot()
        let projectedSession = try XCTUnwrap(projected.session(id: session.id))
        XCTAssertEqual(projectedSession.kind, .codex)
        XCTAssertEqual(projectedSession.title, "Codex")
        XCTAssertTrue(projected.windowLayout.workspaceViews.flatMap(\.tabs).isEmpty)
    }

    func testCreateSessionRequestReceiptPreventsDuplicateRuntime() async throws {
        let runtime = InMemoryTerminalRuntime()
        let service = makeService(runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let projectSnapshot = await service.snapshot()
        let workspace = try XCTUnwrap(
            projectSnapshot.workspaces.first { $0.projectID == project.id }
        )
        let request = TerminalSessionLaunchRequest(
            requestID: UUID(),
            kind: .codex,
            command: "codex",
            title: "Codex"
        )

        let first = try await service.createSession(workspaceID: workspace.id, request: request)
        let replay = try await service.createSession(workspaceID: workspace.id, request: request)

        XCTAssertEqual(first.id, replay.id)
        let runtimeRecords = await runtime.allRecords()
        XCTAssertEqual(runtimeRecords.count, 1)
        let persisted = await service.persistedState()
        XCTAssertEqual(persisted.terminalSessions.count, 1)
        XCTAssertEqual(
            persisted.requestReceipts.filter {
                $0.requestID == request.requestID && $0.commandKind == "create_session"
            }.count,
            1
        )
    }

    func testRestoreMarksMissingRuntimeEndedWithoutCreatingAShell() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let host = WarrenApplicationDefaults.localHost
        let project = Project(hostID: host.id, name: "warren", rootPath: folder.path)
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
        let service = WarrenApplicationService(repository: repository, runtime: runtime)
        try await service.start()

        do {
            _ = try await service.openSession(sessionID: sessionID)
            XCTFail("A missing runtime must not be replaced with a new shell")
        } catch WarrenApplicationError.sessionNotFound {
            // Expected: the durable Session is now ended and stays inspectable.
        }
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.session(id: sessionID)?.lifecycle, .ended)
        XCTAssertEqual(snapshot.session(id: sessionID)?.connectionState, .disconnected)
        let existsAfter = await runtime.exists(sessionID: sessionID)
        XCTAssertFalse(existsAfter)
        let persistedState = await service.persistedState()
        XCTAssertEqual(
            persistedState.terminalSessions.first { $0.id == sessionID }?.lifecycle,
            .ended
        )
    }

    func testStartupMarksMissingHeadlessSessionEndedWithoutRecreatingRuntime() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let host = WarrenApplicationDefaults.localHost
        let project = Project(hostID: host.id, name: "warren", rootPath: folder.path)
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
            title: "Background CLI"
        )
        try await repository.save(PersistedHostState(
            hosts: [host],
            projects: [project],
            workspaces: [workspace],
            terminalSessions: [persisted]
        ))

        let service = WarrenApplicationService(repository: repository, runtime: runtime)
        try await service.start()

        let snapshot = await service.snapshot()
        let runtimeExists = await runtime.exists(sessionID: sessionID)
        XCTAssertEqual(snapshot.sessions.map(\.id), [sessionID])
        XCTAssertEqual(snapshot.session(id: sessionID)?.lifecycle, .ended)
        XCTAssertEqual(snapshot.session(id: sessionID)?.connectionState, .disconnected)
        XCTAssertTrue(snapshot.windowLayout.workspaceViews.flatMap(\.tabs).isEmpty)
        XCTAssertFalse(runtimeExists)
    }

    func testStartupAdoptsRunningHeadlessSessionWithoutCreatingAttachment() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let host = WarrenApplicationDefaults.localHost
        let project = Project(hostID: host.id, name: "warren", rootPath: folder.path)
        let workspace = Workspace(projectID: project.id, name: "main", path: folder.path)
        let sessionID = TerminalSessionID()
        let runtimeDescriptor = try await runtime.create(
            sessionID: sessionID,
            workingDirectory: folder.path,
            size: TerminalSessionCoordinator.defaultTerminalSize,
            launchSpec: .interactiveShell
        )
        let persisted = PersistedTerminalSession(
            id: sessionID,
            workspaceID: workspace.id,
            workingDirectory: folder.path,
            terminalSize: TerminalSessionCoordinator.defaultTerminalSize,
            runtimeAdoptionDescriptor: RuntimeAdoptionDescriptor(
                runtime: runtimeDescriptor.runtime,
                identifier: runtimeDescriptor.identifier,
                metadata: runtimeDescriptor.metadata
            )
        )
        try await repository.save(PersistedHostState(
            hosts: [host],
            projects: [project],
            workspaces: [workspace],
            terminalSessions: [persisted]
        ))

        let service = WarrenApplicationService(repository: repository, runtime: runtime)
        try await service.start()

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.session(id: sessionID)?.lifecycle, .running)
        XCTAssertEqual(snapshot.session(id: sessionID)?.connectionState, .disconnected)
        XCTAssertNil(snapshot.session(id: sessionID)?.tabID)
        XCTAssertNil(snapshot.session(id: sessionID)?.attachmentID)
        let adoptCount = await runtime.adoptCount(for: sessionID)
        XCTAssertEqual(adoptCount, 1)

        let stream = await service.snapshots()
        try await runtime.emitExit(sessionID: sessionID, exitCode: 0)
        _ = try await nextSnapshot(from: stream) {
            $0.session(id: sessionID)?.lifecycle == .ended
        }
    }

    func testExplicitOpenMarksMissingHiddenRuntimeEnded() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let host = WarrenApplicationDefaults.localHost
        let project = Project(hostID: host.id, name: "warren", rootPath: folder.path)
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
            title: "Background CLI"
        )
        try await repository.save(PersistedHostState(
            hosts: [host],
            projects: [project],
            workspaces: [workspace],
            terminalSessions: [persisted]
        ))

        let service = WarrenApplicationService(repository: repository, runtime: runtime)
        try await service.start()
        do {
            _ = try await service.openSession(sessionID: sessionID)
            XCTFail("A missing runtime must not be silently recreated")
        } catch WarrenApplicationError.sessionNotFound {
            // Expected.
        }

        let snapshot = await service.snapshot()
        let runtimeExists = await runtime.exists(sessionID: sessionID)
        XCTAssertTrue(snapshot.tabs(in: workspace.id).isEmpty)
        XCTAssertEqual(snapshot.sessions.map(\.id), [sessionID])
        XCTAssertFalse(runtimeExists)
        XCTAssertEqual(snapshot.session(id: sessionID)?.lifecycle, .ended)
        XCTAssertEqual(snapshot.session(id: sessionID)?.connectionState, .disconnected)
    }

    func testRuntimePresenceFailureKeepsPersistedSessionRunning() async throws {
        let runtime = RestorableRuntime()
        await runtime.setPresence(.unavailable("tmux socket is temporarily unavailable"))
        let repository = InMemoryHostStateRepository()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let host = WarrenApplicationDefaults.localHost
        let project = Project(hostID: host.id, name: "warren", rootPath: folder.path)
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
            )
        )
        try await repository.save(PersistedHostState(
            hosts: [host],
            projects: [project],
            workspaces: [workspace],
            terminalSessions: [persisted]
        ))

        let service = WarrenApplicationService(repository: repository, runtime: runtime)
        try await service.start()
        do {
            _ = try await service.openSession(sessionID: sessionID)
            XCTFail("An unavailable runtime cannot be opened until its presence is known")
        } catch WarrenApplicationError.sessionNotFound {
            // The durable Session remains running and can be retried later.
        }

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.session(id: sessionID)?.lifecycle, .running)
        XCTAssertTrue(snapshot.tabs(in: workspace.id).isEmpty)
        XCTAssertEqual(
            snapshot.issues.first { $0.id == "session.\(sessionID).presence" }?.detail,
            "tmux socket is temporarily unavailable"
        )
        let durable = await service.persistedState()
        XCTAssertEqual(
            durable.terminalSessions.first { $0.id == sessionID }?.lifecycle,
            .running
        )
        let runtimeRecord = await runtime.record(sessionID)
        XCTAssertNil(runtimeRecord)
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

        XCTAssertEqual(afterTabs.tabs(in: firstWorkspace.id).map(\.id), [firstTabID])
        XCTAssertEqual(afterTabs.tabs(in: secondWorkspace.id).map(\.id), [secondTabID])
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

    func testClosingTabsTerminatesRuntimeAndKeepsEndedHistory() async throws {
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

        await service.closeTabs(in: workspace.id, except: second.tabID)
        let afterOthers = await service.snapshot()
        XCTAssertEqual(afterOthers.tabs(in: workspace.id).map(\.id), [secondTabID])
        XCTAssertEqual(afterOthers.sessions.map(\.id), sessions)
        XCTAssertEqual(
            afterOthers.session(id: first.id)?.lifecycle,
            .ended
        )
        XCTAssertNil(afterOthers.session(id: first.id)?.tabID)

        let durableAfterOthers = await service.persistedState()
        let firstStillRunning = await runtime.exists(sessionID: first.id)
        let secondStillRunning = await runtime.exists(sessionID: second.id)
        let thirdStillRunning = await runtime.exists(sessionID: third.id)
        XCTAssertFalse(firstStillRunning)
        XCTAssertTrue(secondStillRunning)
        XCTAssertFalse(thirdStillRunning)
        XCTAssertEqual(
            durableAfterOthers.terminalSessions.first { $0.id == first.id }?.lifecycle,
            .ended
        )

        // A stale close event is an idempotent no-op for the composition root.
        try await service.closeTabIfPresent(tabID: firstTabID, workspaceID: workspace.id)
        await service.closeTabs(in: workspace.id)
        let afterAll = await service.snapshot()
        XCTAssertTrue(afterAll.tabs(in: workspace.id).isEmpty)
        XCTAssertEqual(afterAll.sessions.map(\.id), sessions)
        let firstAlive = await runtime.exists(sessionID: first.id)
        let secondAlive = await runtime.exists(sessionID: second.id)
        let thirdAlive = await runtime.exists(sessionID: third.id)
        XCTAssertFalse(firstAlive)
        XCTAssertFalse(secondAlive)
        XCTAssertFalse(thirdAlive)
        let durable = await service.persistedState()
        XCTAssertEqual(
            Set(durable.terminalSessions.map(\.id)),
            Set(sessions)
        )

        do {
            _ = try await service.openSession(sessionID: first.id)
            XCTFail("An ended Session cannot be reopened as a live Tab")
        } catch WarrenApplicationError.sessionNotFound {
            // Expected. A new Tab creates a new Session.
        }
    }

    func testRuntimeExitWithoutAttachmentStillEndsDurableSession() async throws {
        let runtime = RestorableRuntime()
        let service = makeService(runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let workspace = try await service.rootWorkspace(for: project.id)
        let session = try await service.createSession(workspaceID: workspace.id)

        let before = await service.snapshot()
        XCTAssertNil(before.session(id: session.id)?.tabID)
        XCTAssertNil(before.session(id: session.id)?.attachmentID)
        let snapshots = await service.snapshots()
        try await runtime.emitExit(sessionID: session.id, exitCode: 0)
        let ended = try await nextSnapshot(from: snapshots) {
            $0.session(id: session.id)?.lifecycle == .ended
        }

        XCTAssertNil(ended.session(id: session.id)?.tabID)
        XCTAssertEqual(ended.session(id: session.id)?.connectionState, .disconnected)
        let durable = await service.persistedState()
        XCTAssertEqual(
            durable.terminalSessions.first { $0.id == session.id }?.lifecycle,
            .ended
        )
    }

    func testCloseTabSucceedsWhenRuntimeExitedBeforeLifecycleEventIsPersisted() async throws {
        let runtime = RestorableRuntime()
        let service = makeService(runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let workspace = try await service.rootWorkspace(for: project.id)
        let tabID = try await service.addTab(workspaceID: workspace.id)
        let created = await service.snapshot()
        let sessionID = try XCTUnwrap(
            created.tabs(in: workspace.id).first { $0.id == tabID }?.sessionID
        )

        try await runtime.emitExit(sessionID: sessionID, exitCode: 0)
        try await service.closeTab(tabID: tabID, workspaceID: workspace.id)

        let snapshot = await service.snapshot()
        XCTAssertTrue(snapshot.tabs(in: workspace.id).isEmpty)
        XCTAssertEqual(snapshot.session(id: sessionID)?.lifecycle, .ended)
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

    func testWorkspaceTabSessionStressKeepsEveryResourceInItsOwner() async throws {
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
        let initial = await service.snapshot()
        let firstWorkspace = try XCTUnwrap(
            initial.workspaces.first { $0.projectID == firstProject.id }
        )
        let secondWorkspace = try XCTUnwrap(
            initial.workspaces.first { $0.projectID == secondProject.id }
        )
        let workspaceIDs = [firstWorkspace.id, secondWorkspace.id]

        for round in 0..<100 {
            let target = workspaceIDs[round % workspaceIDs.count]
            let other = workspaceIDs[(round + 1) % workspaceIDs.count]
            let request = TerminalSessionLaunchRequest(
                requestID: UUID(),
                kind: .shell,
                title: "Stress \(round)"
            )
            async let createdTab = service.addTab(workspaceID: target, request: request)
            async let switchedAway: Void = service.selectWorkspace(other)
            let (tabID, _) = try await (createdTab, switchedAway)

            let snapshot = await service.snapshot()
            let sessionID = try XCTUnwrap(
                snapshot.tabs(in: target).first { $0.id == tabID }?.sessionID
            )
            XCTAssertEqual(snapshot.session(id: sessionID)?.workspaceID, target)
            XCTAssertFalse(snapshot.tabs(in: other).contains { $0.id == tabID })
            XCTAssertEqual(
                snapshot.windowLayout.workspaceView(for: target)?.tabs
                    .compactMap(\.sessionID)
                    .filter { $0 == sessionID }.count,
                1
            )

            if round % 3 == 0 {
                try await service.closeTabIfPresent(tabID: tabID, workspaceID: target)
                let closed = await service.snapshot()
                XCTAssertFalse(closed.tabs(in: target).contains { $0.id == tabID })
                XCTAssertNotNil(closed.session(id: sessionID))
                let runtimeAlive = await runtime.exists(sessionID: sessionID)
                XCTAssertFalse(runtimeAlive)
                XCTAssertEqual(closed.session(id: sessionID)?.lifecycle, .ended)
                XCTAssertNil(closed.session(id: sessionID)?.tabID)
            }
        }

        let final = await service.snapshot()
        for view in final.windowLayout.workspaceViews {
            XCTAssertEqual(Set(view.tabs.map(\.id)).count, view.tabs.count)
            for tab in view.tabs {
                let sessionID = try XCTUnwrap(tab.sessionID)
                XCTAssertEqual(final.session(id: sessionID)?.workspaceID, view.workspaceID)
            }
        }
        let persisted = await service.persistedState()
        XCTAssertEqual(persisted.terminalSessions.count, 100)
        XCTAssertEqual(
            persisted.requestReceipts.filter { $0.commandKind == "create_session" }.count,
            100
        )
    }

    func testRepeatedEmptyWorkspaceSelectionCoalescesOneDefaultShellTab() async throws {
        let runtime = RestorableRuntime()
        let service = makeService(runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let initial = await service.snapshot()
        let workspace = try XCTUnwrap(
            initial.workspaces.first { $0.projectID == project.id }
        )

        async let first = service.ensureDefaultShellTab(workspaceID: workspace.id)
        async let second = service.ensureDefaultShellTab(workspaceID: workspace.id)
        async let third = service.ensureDefaultShellTab(workspaceID: workspace.id)
        let tabIDs = try await [first, second, third]

        let snapshot = await service.snapshot()
        XCTAssertEqual(Set(tabIDs).count, 1)
        XCTAssertEqual(snapshot.tabs(in: workspace.id).count, 1)
        XCTAssertEqual(snapshot.sessions(in: workspace.id).count, 1)
        XCTAssertEqual(snapshot.sessions(in: workspace.id).first?.kind, .shell)
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
            data: Data("echo warren\n".utf8)
        )
        let size = try XCTUnwrap(TerminalSize(columns: 120, rows: 40))
        try await service.resize(sessionID: session.id, attachmentID: attachment, size: size)

        let runtimeRecord = await runtime.record(session.id)
        let input = try XCTUnwrap(runtimeRecord?.writes.last)
        XCTAssertEqual(input, Data("echo warren\n".utf8))
        XCTAssertEqual(runtimeRecord?.resizes.last, size)
        let resizedSnapshot = await service.snapshot()
        XCTAssertEqual(resizedSnapshot.session(id: session.id)?.terminalSize, size)
        let resizedState = await service.persistedState()
        XCTAssertEqual(
            resizedState.terminalSessions.first { $0.id == session.id }?.terminalSize,
            size
        )

        let stream = await service.snapshots()
        let marker = Data("WARREN_OUTPUT".utf8)
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

    func testTypedKeyInspectionAndTerminationPersistEndedLifecycle() async throws {
        let runtime = InMemoryTerminalRuntime()
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
        let session = try XCTUnwrap(
            tabSnapshot.sessions.first { $0.tabID == tabID }
        )
        let attachmentID = try XCTUnwrap(session.attachmentID)

        try await service.sendSpecialKey(
            sessionID: session.id,
            attachmentID: attachmentID,
            key: .interrupt
        )
        let inspection = try await service.inspectSessionRuntime(sessionID: session.id)
        try await service.terminateSession(sessionID: session.id)

        XCTAssertTrue(inspection.isRunning)
        let runtimeRecord = await runtime.record(for: session.id)
        XCTAssertEqual(runtimeRecord?.writes.last, Data([0x03]))
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.session(id: session.id)?.lifecycle, .ended)
        XCTAssertEqual(snapshot.session(id: session.id)?.connectionState, .disconnected)
        let persisted = await service.persistedState()
        XCTAssertEqual(
            persisted.terminalSessions.first { $0.id == session.id }?.lifecycle,
            .ended
        )
        XCTAssertNotNil(
            persisted.terminalSessions.first { $0.id == session.id }?.endedAt
        )
    }

    func testDeleteSessionTerminatesRuntimeAndRemovesTabAndDurableRecord() async throws {
        let runtime = InMemoryTerminalRuntime()
        let service = makeService(runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let workspace = try await service.rootWorkspace(for: project.id)
        let deletedTabID = try await service.addTab(workspaceID: workspace.id, title: "Delete")
        let retainedTabID = try await service.addTab(workspaceID: workspace.id, title: "Keep")
        let before = await service.snapshot()
        let deletedSessionID = try XCTUnwrap(
            before.tabs(in: workspace.id).first { $0.id == deletedTabID }?.sessionID
        )
        let retainedSessionID = try XCTUnwrap(
            before.tabs(in: workspace.id).first { $0.id == retainedTabID }?.sessionID
        )

        try await service.deleteSession(sessionID: deletedSessionID)

        let deletedRuntimeExists = await runtime.exists(sessionID: deletedSessionID)
        let retainedRuntimeExists = await runtime.exists(sessionID: retainedSessionID)
        XCTAssertFalse(deletedRuntimeExists)
        XCTAssertTrue(retainedRuntimeExists)
        let after = await service.snapshot()
        XCTAssertNil(after.session(id: deletedSessionID))
        XCTAssertEqual(after.tabs(in: workspace.id).map(\.id), [retainedTabID])
        let persisted = await service.persistedState()
        XCTAssertFalse(persisted.terminalSessions.contains { $0.id == deletedSessionID })
        XCTAssertTrue(persisted.terminalSessions.contains { $0.id == retainedSessionID })
    }

    func testDeleteAlreadyExitedSessionRemovesHistoryWithoutRevivingRuntime() async throws {
        let runtime = InMemoryTerminalRuntime()
        let service = makeService(runtime: runtime)
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let workspace = try await service.rootWorkspace(for: project.id)
        let session = try await service.createSession(workspaceID: workspace.id)
        try await service.terminateSession(sessionID: session.id)

        try await service.deleteSession(sessionID: session.id)

        let runtimeExists = await runtime.exists(sessionID: session.id)
        let snapshot = await service.snapshot()
        let persisted = await service.persistedState()
        XCTAssertFalse(runtimeExists)
        XCTAssertNil(snapshot.session(id: session.id))
        XCTAssertFalse(persisted.terminalSessions.contains { $0.id == session.id })
    }

    func testRuntimeExitAndTerminateRaceKeepsFirstEndedTimestamp() async throws {
        let runtime = RestorableRuntime()
        let repository = InMemoryHostStateRepository()
        let clock = AdvancingClock(base: Date(timeIntervalSince1970: 1_700_000_000))
        let service = WarrenApplicationService(
            repository: repository,
            runtime: runtime,
            clock: { clock.next() }
        )
        try await service.start()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try await service.addProject(folder: folder)
        let projectSnapshot = await service.snapshot()
        let workspace = try XCTUnwrap(
            projectSnapshot.workspaces.first { $0.projectID == project.id }
        )
        let session = try await service.createSession(workspaceID: workspace.id)
        _ = try await service.attach(sessionID: session.id)

        try await service.terminateSession(sessionID: session.id)
        let immediatelyPersisted = await service.persistedState()
        let firstEndedAt = try XCTUnwrap(
            immediatelyPersisted.terminalSessions.first { $0.id == session.id }?.endedAt
        )
        try? await Task.sleep(for: .milliseconds(50))

        let persisted = await service.persistedState()
        XCTAssertEqual(
            persisted.terminalSessions.first { $0.id == session.id }?.endedAt,
            firstEndedAt
        )
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
        _ = try await second.openSession(sessionID: created.id)
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
    ) -> WarrenApplicationService {
        WarrenApplicationService(repository: repository, runtime: runtime)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-application-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func runGit(_ arguments: [String]) throws {
        _ = try gitOutput(arguments)
    }

    private func gitOutput(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WarrenApplicationTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                        as: UTF8.self
                    ),
                ]
            )
        }
        return String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nextSnapshot(
        from stream: AsyncStream<WarrenApplicationSnapshot>,
        matching predicate: @escaping @Sendable (WarrenApplicationSnapshot) -> Bool
    ) async throws -> WarrenApplicationSnapshot {
        try await withThrowingTaskGroup(of: WarrenApplicationSnapshot.self) { group in
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

private final class AdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base: Date
    private var index = 0

    init(base: Date) {
        self.base = base
    }

    func next() -> Date {
        lock.withLock {
            defer { index += 1 }
            return base.addingTimeInterval(TimeInterval(index * 60))
        }
    }

}

private actor WorktreeManagerSpy: GitWorktreeManaging {
    private(set) var creations: [GitWorktreeCreation] = []
    private(set) var removals: [GitWorktreeCreation] = []

    func create(_ request: GitWorktreeCreation) async throws {
        creations.append(request)
    }

    func remove(_ request: GitWorktreeCreation) async throws {
        removals.append(request)
    }
}
