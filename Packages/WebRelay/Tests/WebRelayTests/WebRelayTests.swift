import XCTest
import Foundation
import WarrenApplication
import WarrenDomain
import WarrenHost
import WarrenStateStore
@testable import WebRelay

final class WebRelayTests: XCTestCase {
    @MainActor
    func testRosterKeepsHostSessionsSeparateFromVisibleTabs() async throws {
        let service = WarrenApplicationService(
            repository: InMemoryHostStateRepository(),
            runtime: InMemoryTerminalRuntime()
        )
        try await service.start()
        defer { Task { await service.shutdown() } }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-web-roster-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try await service.addProject(folder: directory)
        let workspace = try await service.rootWorkspace(for: project.id)
        let tabID = try await service.addTab(workspaceID: workspace.id, title: "Visible")
        let snapshot = await service.snapshot()
        let sessionID = try XCTUnwrap(snapshot.tabs(in: workspace.id).first?.sessionID)
        let relay = WebRelayServer(service: service)

        var roster = try Self.decodeJSON(await relay.rosterJSON())
        XCTAssertEqual(Self.ids(in: roster, key: "sessions"), [sessionID.description])
        XCTAssertEqual(Self.ids(in: roster, key: "tabs"), [tabID])

        try await service.closeTab(tabID: tabID, workspaceID: workspace.id)
        roster = try Self.decodeJSON(await relay.rosterJSON())
        XCTAssertEqual(Self.ids(in: roster, key: "sessions"), [sessionID.description])
        XCTAssertTrue(Self.ids(in: roster, key: "tabs").isEmpty)

        try await service.terminateSession(sessionID: sessionID)
        roster = try Self.decodeJSON(await relay.rosterJSON())
        let sessions = try XCTUnwrap(roster["sessions"] as? [[String: String]])
        XCTAssertEqual(sessions.first?["state"], "exited")
        XCTAssertTrue(Self.ids(in: roster, key: "tabs").isEmpty)
    }

    func testRelayEnvelopeRoundTripAndAuthRewriteStaysAtHostEdge() throws {
        let connectionID = RelayHostConnector.ConnectionID(
            bytes: Data((0..<16).map(UInt8.init))
        )
        let original = RelayHostConnector.RelayFrame(
            kind: .binary,
            connectionID: connectionID,
            payload: Data([0, 1, 2, 255])
        )
        let decoded = try XCTUnwrap(RelayHostConnector.decode(RelayHostConnector.encode(original)))
        XCTAssertEqual(decoded.kind, .binary)
        XCTAssertEqual(decoded.connectionID, connectionID)
        XCTAssertEqual(decoded.payload, original.payload)
        XCTAssertNil(RelayHostConnector.decode(Data("BRLY".utf8)))

        let remoteAuth = Data(#"{"t":"auth","token":"remote-access-token"}"#.utf8)
        let rewritten = try XCTUnwrap(RelayHostConnector.rewrittenAuthPayload(
            remoteAuth,
            localPairingToken: "local-pairing-token"
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rewritten) as? [String: String]
        )
        XCTAssertEqual(object["token"], "local-pairing-token")
        XCTAssertFalse(String(decoding: rewritten, as: UTF8.self).contains("remote-access-token"))
    }

    @MainActor
    func testLoopbackHTTPHookAndWebSocketAuthentication() async throws {
        let service = WarrenApplicationService(
            repository: InMemoryHostStateRepository(),
            runtime: InMemoryTerminalRuntime()
        )
        try await service.start()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-web-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try await service.addProject(folder: directory)
        let workspace = try await service.rootWorkspace(for: project.id)
        let session = try await service.createSession(workspaceID: workspace.id, kind: .codex)
        let relay = WebRelayServer(service: service)
        relay.start(port: 0)
        let port = try XCTUnwrap(relay.listeningPort)
        defer {
            relay.stop()
            Task { await service.shutdown() }
        }
        let base = URL(string: "http://127.0.0.1:\(port)")!

        for path in [
            "/", "/manifest.webmanifest", "/service-worker.js", "/icon.svg",
            "/icon-192.png", "/icon-512.png", "/apple-touch-icon.png",
            "/preset-shell.svg", "/preset-claude.svg", "/preset-codex.svg",
            "/preset-codex-white.svg",
        ] {
            let url = URL(string: path, relativeTo: base)!
            let (data, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, path)
            XCTAssertFalse(data.isEmpty, path)
        }

        var hook = URLComponents(url: base.appendingPathComponent("hook"), resolvingAgainstBaseURL: false)!
        hook.queryItems = [
            URLQueryItem(name: "session", value: session.id.description),
            URLQueryItem(name: "state", value: TerminalSessionActivityState.waitingForInput.rawValue),
            URLQueryItem(name: "token", value: WebRelayServer.accessToken),
        ]
        let (_, hookResponse) = try await URLSession.shared.data(from: try XCTUnwrap(hook.url))
        XCTAssertEqual((hookResponse as? HTTPURLResponse)?.statusCode, 204)
        try await Task.sleep(for: .milliseconds(20))
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.session(id: session.id)?.activityState, .waitingForInput)

        let socket = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/ws")!
        )
        socket.resume()
        try await socket.send(.string(#"{"t":"auth","token":"wrong"}"#))
        let message = try await socket.receive()
        guard case .string(let text) = message else {
            return XCTFail("Expected an authentication error frame")
        }
        XCTAssertTrue(text.contains("unauthorized"))
        socket.cancel(with: .normalClosure, reason: nil)
    }

    @MainActor
    func testWebPageResourceIsBundled() {
        XCTAssertNotNil(WebRelayServer.webPageURL)
        let html = try! XCTUnwrap(WebRelayServer.webPageHTML)
        XCTAssertTrue(html.contains("manifest.webmanifest"))
        XCTAssertTrue(html.contains("class=\"sidebar\""))
        XCTAssertTrue(html.contains("class=\"mobile-keys\""))
        XCTAssertTrue(html.contains("waitingForInput"))
        XCTAssertTrue(html.contains("ready:\"Ready\""))
        XCTAssertTrue(html.contains("const workspaceTabs"))
        XCTAssertTrue(html.contains("tabs:msg.tabs || []"))
        XCTAssertTrue(html.contains("attachedSession === activeSession"))
        XCTAssertTrue(html.contains("location.search || location.hash"))
        XCTAssertTrue(html.contains("__WARREN_INJECTED_PARAMS__"))
        XCTAssertTrue(html.contains("__WARREN_RELAY_HOST_ID__"))
        XCTAssertTrue(html.contains("warren.accessToken.${relayHostID}"))
        XCTAssertTrue(html.contains("/v1/client/connect?host_id="))
        XCTAssertTrue(html.contains("class=\"preset\" data-kind=\"shell\""))
        XCTAssertTrue(html.contains("/preset-claude.svg"))
        XCTAssertTrue(html.contains("id=\"pane-title\""))
        XCTAssertTrue(html.contains("id=\"settings-page\""))
        XCTAssertTrue(html.contains("id=\"settings-back\""))
        XCTAssertTrue(html.contains("id=\"font-family\""))
        XCTAssertTrue(html.contains("id=\"font-size\""))
        XCTAssertTrue(html.contains("id=\"search-panel\""))
        XCTAssertTrue(html.contains("const renderSearch"))
        XCTAssertTrue(html.contains("id=\"sessions\""))
        XCTAssertTrue(html.contains("data-delete-session"))
        XCTAssertTrue(html.contains("t:\"deleteSession\""))
        XCTAssertTrue(html.contains("warren.terminalTitleTemplate"))
        XCTAssertTrue(html.contains("warren.terminalFontFamily"))
        XCTAssertFalse(html.contains("class=\"count\""))
        XCTAssertTrue(html.contains("const rebuildIndexes"))
        XCTAssertTrue(html.contains("let sessionByID = new Map()"))
        XCTAssertFalse(html.contains("access_token=${encodeURIComponent(token)}"))
        XCTAssertNotNil(WebRelayServer.resourceData(named: "manifest", extension: "webmanifest"))
        XCTAssertNotNil(WebRelayServer.resourceData(named: "service-worker", extension: "js"))
        XCTAssertNotNil(WebRelayServer.resourceData(named: "icon", extension: "svg"))
        XCTAssertNotNil(WebRelayServer.resourceData(named: "icon-192", extension: "png"))
        XCTAssertNotNil(WebRelayServer.resourceData(named: "icon-512", extension: "png"))
        XCTAssertNotNil(WebRelayServer.resourceData(named: "apple-touch-icon", extension: "png"))
        for name in ["preset-shell", "preset-claude", "preset-codex", "preset-codex-white"] {
            XCTAssertNotNil(WebRelayServer.resourceData(named: name, extension: "svg"), name)
        }
        XCTAssertNotNil(WebRelayServer.webPageURLWithToken)
        XCTAssertEqual(WebRelayServer.localWebURL?.host, "127.0.0.1")
        XCTAssertEqual(WebRelayServer.localWebURL?.port, Int(WebRelayServer.defaultPort))
        XCTAssertTrue(WebRelayServer.localWebURL?.fragment?.hasPrefix("t=") == true)
        XCTAssertNotNil(WebRelayServer.webPageURL(host: "abc.trycloudflare.com"))
        let dataURL = try! XCTUnwrap(WebRelayServer.webPageDataURL(host: "abc.trycloudflare.com"))
        XCTAssertTrue(dataURL.absoluteString.hasPrefix("data:text/html;base64,"))
        let encodedHTML = try! XCTUnwrap(dataURL.absoluteString.split(separator: ",", maxSplits: 1).last)
        let injectedHTML = String(
            data: try! XCTUnwrap(Data(base64Encoded: String(encodedHTML))),
            encoding: .utf8
        )
        XCTAssertTrue(injectedHTML?.contains("host=abc.trycloudflare.com&t=\(WebRelayServer.accessToken)") == true)
        XCTAssertFalse(injectedHTML?.contains("__WARREN_INJECTED_PARAMS__") == true)

        let hostileURL = try! XCTUnwrap(WebRelayServer.webPageDataURL(host: #"host";alert(1)//"#))
        let hostileEncodedHTML = try! XCTUnwrap(
            hostileURL.absoluteString.split(separator: ",", maxSplits: 1).last
        )
        let hostileHTML = String(
            data: try! XCTUnwrap(Data(base64Encoded: String(hostileEncodedHTML))),
            encoding: .utf8
        )
        XCTAssertFalse(hostileHTML?.contains(#"host";alert(1)//"#) == true)
        XCTAssertTrue(hostileHTML?.contains("host%22;alert(1)//") == true)
    }

    func testManagedHookScriptMapsStopToReadyAndPermissionToWaiting() throws {
        let script = try XCTUnwrap(AgentHookInstaller.scriptForTesting())
        XCTAssertTrue(script.contains("PermissionRequest|exec_approval_request|apply_patch_approval_request|request_user_input) STATE=waitingForInput"))
        XCTAssertTrue(script.contains("Stop|agent-turn-complete|task_complete) STATE=ready"))
    }

    func testManagedHookMergePreservesUserEntriesAndIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let original: [String: Any] = [
            "model": "user-model",
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "user-notify"]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: url)

        AgentHookInstaller.mergeHooksForTesting(
            at: url,
            events: ["Stop", "PermissionRequest"],
            command: "notify # \(AgentHookInstaller.marker)"
        )
        AgentHookInstaller.mergeHooksForTesting(
            at: url,
            events: ["Stop", "PermissionRequest"],
            command: "notify # \(AgentHookInstaller.marker)"
        )

        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(result["model"] as? String, "user-model")
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        XCTAssertTrue(encoded.contains("user-notify"))
        XCTAssertEqual(encoded.components(separatedBy: AgentHookInstaller.marker).count - 1, 2)
    }

    private static func decodeJSON(_ value: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
        )
    }

    private static func ids(in object: [String: Any], key: String) -> [String] {
        (object[key] as? [[String: String]] ?? []).compactMap { $0["id"] }
    }

    @MainActor
    func testTunnelURLParsing() {
        let output = """
        INF Registered tunnel connection
        https://loud-words-trycloudflare-com.trycloudflare.com
        """
        XCTAssertEqual(
            WebRelayServer.parseTunnelURL(from: output)?.absoluteString,
            "https://loud-words-trycloudflare-com.trycloudflare.com"
        )
        let tailscaleJSON = """
        {"TCP":{"443":{"HTTPS":true}},"Web":{"bilibili.tail3d6e0.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8788"}}}}}
        """
        XCTAssertEqual(
            WebRelayServer.parseTailscaleURL(from: tailscaleJSON)?.absoluteString,
            "https://bilibili.tail3d6e0.ts.net/"
        )
        let funnelJSON = """
        {"TCP":{"443":{"HTTPS":true}},"Funnel":{"bilibili.tail3d6e0.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8788"}}}}}
        """
        XCTAssertEqual(
            WebRelayServer.parseTailscaleURL(from: funnelJSON)?.absoluteString,
            "https://bilibili.tail3d6e0.ts.net/"
        )
    }

}
