import Foundation

public protocol TmuxControlling: Sendable {

    // MARK: - Phase 1 (implemented)

    func scanAll() async throws -> [TmuxSession]
    func createSession(name: String, cwd: String) async throws -> TmuxSession
    func selectWindow(sessionId: String, windowId: String) async throws
    func killSession(id: String) async throws
    func isAvailable() async -> Bool

    // MARK: - Future phases (default implementations throw)

    func selectSession(id: String) async throws
    func selectPane(sessionId: String, paneId: String) async throws
    func createWindow(sessionId: String, name: String?, cwd: String?) async throws -> TmuxWindow
    func splitPane(sessionId: String, paneId: String, horizontal: Bool, cwd: String?) async throws -> TmuxPane
    func renameWindow(sessionId: String, windowId: String, newName: String) async throws
    func sendKeys(sessionId: String, paneId: String, keys: String) async throws
    func killWindow(sessionId: String, windowId: String) async throws
    func killPane(sessionId: String, paneId: String) async throws
    func setServerOption(option: String, value: String) async throws
    func setOption(sessionId: String?, option: String, value: String) async throws
    func setWindowOption(global: Bool, target: String?, option: String, value: String) async throws
    func refreshClients() async throws
    func navigatePane(sessionId: String, direction: PaneDirection) async throws
    func resizePane(sessionId: String, direction: PaneDirection, amount: Int) async throws
    func togglePaneZoom(sessionId: String) async throws
    func equalizePanes(sessionId: String) async throws
    func capturePaneOutput(paneId: String, lineCount: Int) async throws -> String
}

// MARK: - Default implementations for future-phase methods

public extension TmuxControlling {

    func selectSession(id: String) async throws {
        throw TmuxError.notYetImplemented("selectSession")
    }

    func selectPane(sessionId: String, paneId: String) async throws {
        throw TmuxError.notYetImplemented("selectPane")
    }

    func createWindow(sessionId: String, name: String?, cwd: String?) async throws -> TmuxWindow {
        throw TmuxError.notYetImplemented("createWindow")
    }

    func splitPane(sessionId: String, paneId: String, horizontal: Bool, cwd: String?) async throws -> TmuxPane {
        throw TmuxError.notYetImplemented("splitPane")
    }

    func renameWindow(sessionId: String, windowId: String, newName: String) async throws {
        throw TmuxError.notYetImplemented("renameWindow")
    }

    func sendKeys(sessionId: String, paneId: String, keys: String) async throws {
        throw TmuxError.notYetImplemented("sendKeys")
    }

    func killWindow(sessionId: String, windowId: String) async throws {
        throw TmuxError.notYetImplemented("killWindow")
    }

    func killPane(sessionId: String, paneId: String) async throws {
        throw TmuxError.notYetImplemented("killPane")
    }

    func setServerOption(option: String, value: String) async throws {
        throw TmuxError.notYetImplemented("setServerOption")
    }

    func setOption(sessionId: String?, option: String, value: String) async throws {
        throw TmuxError.notYetImplemented("setOption")
    }

    func setWindowOption(global: Bool, target: String?, option: String, value: String) async throws {
        throw TmuxError.notYetImplemented("setWindowOption")
    }

    func refreshClients() async throws {
        throw TmuxError.notYetImplemented("refreshClients")
    }

    func capturePaneOutput(paneId: String, lineCount: Int) async throws -> String {
        throw TmuxError.notYetImplemented("capturePaneOutput")
    }

    func navigatePane(sessionId: String, direction: PaneDirection) async throws {
        throw TmuxError.notYetImplemented("navigatePane")
    }

    func resizePane(sessionId: String, direction: PaneDirection, amount: Int) async throws {
        throw TmuxError.notYetImplemented("resizePane")
    }

    func togglePaneZoom(sessionId: String) async throws {
        throw TmuxError.notYetImplemented("togglePaneZoom")
    }

    func equalizePanes(sessionId: String) async throws {
        throw TmuxError.notYetImplemented("equalizePanes")
    }
}
