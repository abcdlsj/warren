import AppKit
import SwiftUI
import BurrowDomain
import GhosttyAdapter

/// Verifies the real AppKit input path across terminal switches.
///
/// The probe verifies first-responder ownership, then injects one byte through
/// the in-memory backend selected by that responder. Synthetic `NSEvent`
/// translation is intentionally excluded: headless SwiftPM executables do not
/// become the active macOS application reliably in CI. The A → B → A sequence
/// still catches focus being left on a hidden sibling.
@MainActor
final class InputProbeApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var model: InputProbeModel!
    private var received: [TerminalSessionID: Data] = [:]
    private var resized: [TerminalSessionID: [(columns: Int, rows: Int)]] = [:]
    private let firstSessionID = TerminalSessionID()
    private let secondSessionID = TerminalSessionID()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let firstSurface = makeSurface(id: firstSessionID)
        let secondSurface = makeSurface(id: secondSessionID)
        model = InputProbeModel(
            selectedSessionID: firstSessionID,
            surfaces: [
                firstSessionID: firstSurface,
                secondSessionID: secondSurface,
            ]
        )

        let content = InputProbeContent(model: model)
            .frame(width: 800, height: 500)
            .background(Color.black)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 500)

        window = BurrowInputWindow(
            contentRect: NSRect(x: 200, y: 200, width: 800, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.contentView = hosting
        activateWindow()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.runStep(sessionID: self?.firstSessionID, keyCode: 0, expectedByte: 1) {
                guard let self else { return }
                self.runStep(sessionID: self.secondSessionID, keyCode: 11, expectedByte: 2) {
                    self.runStep(sessionID: self.firstSessionID, keyCode: 8, expectedByte: 3) {
                        self.validateResult()
                    }
                }
            }
        }
    }

    private func makeSurface(id: TerminalSessionID) -> GhosttySurface {
        GhosttySurface(
            id: id,
            attachmentID: TerminalAttachmentID(),
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            onInput: { [weak self] data in
                DispatchQueue.main.async {
                    self?.received[id, default: Data()].append(data)
                    print("INPUT \(id) \(String(decoding: data, as: UTF8.self))")
                }
            },
            onResize: { [weak self] columns, rows in
                DispatchQueue.main.async {
                    self?.resized[id, default: []].append((columns, rows))
                    print("RESIZE \(id) \(columns)x\(rows)")
                }
            }
        )
    }

    private func runStep(
        sessionID: TerminalSessionID?,
        keyCode: UInt16,
        expectedByte: UInt8,
        completion: @escaping () -> Void
    ) {
        guard let sessionID else {
            finish(passed: false, detail: "missing session ID")
            return
        }
        model.selectedSessionID = sessionID
        activateWindow()

        waitForTerminalFirstResponder(sessionID: sessionID, retries: 12) { [weak self] focused in
            guard let self else { return }
            guard focused else {
                self.finish(
                    passed: false,
                    detail: "terminal never became first responder for \(sessionID)"
                )
                return
            }
            self.sendControlKey(keyCode: keyCode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let receivedByte = self.received[sessionID]?.last
                guard receivedByte == expectedByte else {
                    self.finish(
                        passed: false,
                        detail: "session \(sessionID) expected \(expectedByte), got \(String(describing: receivedByte))"
                    )
                    return
                }
                completion()
            }
        }
    }

    private func waitForTerminalFirstResponder(
        sessionID: TerminalSessionID,
        retries: Int,
        completion: @escaping (Bool) -> Void
    ) {
        let responderName = window.firstResponder.map { String(describing: type(of: $0)) }
        print("FOCUS firstResponder=\(responderName ?? "nil")")
        if responderName?.contains("AppTerminalView") == true,
           model.focusedSessionID == sessionID {
            completion(true)
            return
        }
        guard retries > 0 else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForTerminalFirstResponder(
                sessionID: sessionID,
                retries: retries - 1,
                completion: completion
            )
        }
    }

    private func activateWindow() {
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func sendControlKey(keyCode: UInt16) {
        let byte = keyCode == 0 ? UInt8(1) : keyCode == 11 ? UInt8(2) : UInt8(3)
        guard let sessionID = model.focusedSessionID,
              let surface = model.surfaces[sessionID],
              window.firstResponder is NSView else { return }
        surface.inMemory.sendInput(Data([byte]))
    }

    private func validateResult() {
        let first = Array(received[firstSessionID] ?? Data())
        let second = Array(received[secondSessionID] ?? Data())
        let firstSize = resized[firstSessionID]?.last
        let secondSize = resized[secondSessionID]?.last
        let filledFirst = firstSize.map { $0.columns >= 80 && $0.rows >= 24 } ?? false
        let filledSecond = secondSize.map { $0.columns >= 80 && $0.rows >= 24 } ?? false
        let passed = first.suffix(2) == [1, 3]
            && second.suffix(1) == [2]
            && filledFirst
            && filledSecond
        finish(
            passed: passed,
            detail: "first=\(first),second=\(second),firstSize=\(String(describing: firstSize)),secondSize=\(String(describing: secondSize))"
        )
    }

    private func finish(passed: Bool, detail: String) {
        print("RECEIVED \(detail)")
        try? """
        {"passed": \(passed), "detail": "\(detail)"}
        """.write(
            to: URL(fileURLWithPath: "/tmp/inputprobe-report.json"),
            atomically: true,
            encoding: .utf8
        )
        print(passed ? "InputProbe passed." : "InputProbe FAILED.")
        exit(passed ? 0 : 1)
    }
}

@MainActor
private final class InputProbeModel: ObservableObject {
    @Published var selectedSessionID: TerminalSessionID
    @Published var focusedSessionID: TerminalSessionID?
    let surfaces: [TerminalSessionID: GhosttySurface]

    init(
        selectedSessionID: TerminalSessionID,
        surfaces: [TerminalSessionID: GhosttySurface]
    ) {
        self.selectedSessionID = selectedSessionID
        self.surfaces = surfaces
    }
}

private struct InputProbeContent: View {
    @ObservedObject var model: InputProbeModel
    @State private var focusDriver = GhosttyFocusDriver()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach([TerminalSessionID](model.surfaces.keys), id: \.self) { sessionID in
                    if let surface = model.surfaces[sessionID] {
                        let isActive = model.selectedSessionID == sessionID
                        GhosttyManagedSurface(
                            surface: surface,
                            isActive: isActive,
                            focusDriver: focusDriver,
                            viewportSize: proxy.size,
                            onFocused: {
                                if isActive {
                                    model.focusedSessionID = sessionID
                                }
                            }
                        )
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                            .onDisappear {
                                if model.focusedSessionID == sessionID {
                                    model.focusedSessionID = nil
                                }
                            }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private final class BurrowInputWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

let app = NSApplication.shared
let delegate = InputProbeApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
