import AppKit
import SwiftUI
import BurrowDesktop
import BurrowDomain
import Vision

private struct ClickProbeRoot: View {
    let projection: BurrowDesktopProjection
    let onAction: @MainActor (BurrowDesktopAction) -> Void
    let onNavigation: @MainActor (BurrowDesktopNavigationState) -> Void
    @State private var navigation: BurrowDesktopNavigationState

    init(
        projection: BurrowDesktopProjection,
        onAction: @escaping @MainActor (BurrowDesktopAction) -> Void,
        onNavigation: @escaping @MainActor (BurrowDesktopNavigationState) -> Void
    ) {
        self.projection = projection
        self.onAction = onAction
        self.onNavigation = onNavigation
        _navigation = State(
            initialValue: BurrowDesktopNavigationReducer.initial(for: projection)
        )
    }

    var body: some View {
        BurrowDesktopRoot(
            projection: projection,
            navigation: navigation,
            actions: BurrowDesktopActions { action in
                navigation = BurrowDesktopNavigationReducer.reduce(
                    navigation,
                    action: action,
                    in: projection
                )
                onNavigation(navigation)
                onAction(action)
            }
        ) { context in
            Text("probe:\(context.tab.id)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .foregroundStyle(Color.green)
        }
    }
}

/// A live-window interaction probe.
///
/// It renders the real desktop shell, uses Vision OCR to locate text-labeled
/// controls, synthesizes real NSEvents for clicks and mouse moves, and verifies
/// that each control reaches the action channel (or visibly opens the command
/// palette). Results are written to `/tmp/clickprobe-report.json` and the
/// process exits non-zero when any expected response is missing.
@MainActor
final class ClickProbeApp: NSObject, NSApplicationDelegate {
    private struct Scenario {
        let name: String
        let projection: BurrowDesktopProjection
        let steps: [Step]
    }

    private struct Step {
        let name: String
        let locate: (OCRIndex) -> CGPoint?
        let candidates: ((OCRIndex) -> [CGPoint])?
        let expectedAction: String?
        let expectedTabID: String?
        let opensPalette: Bool

        init(
            name: String,
            locate: @escaping (OCRIndex) -> CGPoint?,
            candidates: ((OCRIndex) -> [CGPoint])? = nil,
            expectedAction: String? = nil,
            expectedTabID: String? = nil,
            opensPalette: Bool = false
        ) {
            self.name = name
            self.locate = locate
            self.candidates = candidates
            self.expectedAction = expectedAction
            self.expectedTabID = expectedTabID
            self.opensPalette = opensPalette
        }
    }

    private struct StepResult: Codable {
        let name: String
        let point: Point
        let passed: Bool
        let detail: String
    }

    private struct ScenarioResult: Codable {
        let name: String
        let steps: [StepResult]
        let actions: [String]
        let passed: Bool
    }

    private struct Report: Codable {
        let scenarios: [ScenarioResult]
        let passed: Bool
    }

    private struct Point: Codable {
        let x: Double
        let y: Double
    }

    private struct OCRText {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        var center: CGPoint {
            CGPoint(x: x + width / 2, y: y + height / 2)
        }
    }

    private struct OCRIndex {
        let texts: [OCRText]

        func first(
            containing needle: String,
            minX: CGFloat = 0,
            maxX: CGFloat = .infinity,
            minY: CGFloat = 0,
            maxY: CGFloat = .infinity
        ) -> OCRText? {
            texts.first {
                $0.text.localizedCaseInsensitiveContains(needle)
                    && $0.x >= minX && $0.x <= maxX
                    && $0.y >= minY && $0.y <= maxY
            }
        }

        func all(containing needle: String) -> [OCRText] {
            texts.filter { $0.text.localizedCaseInsensitiveContains(needle) }
        }

        func y(of exact: String) -> CGFloat? {
            texts.first { $0.text == exact }?.y
        }
    }

    private var window: NSWindow!
    private var hosting: NSHostingView<AnyView>?
    private var received: [String] = []
    private var scenarioResults: [ScenarioResult] = []
    private var currentScenario: Scenario?
    private var currentSteps: [StepResult] = []
    private var currentNavigation = BurrowDesktopNavigationState()
    private var stepIndex = 0

    private let windowSize = CGSize(width: 1280, height: 800)

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "burrow.desktop.sidebarCollapsed")
        UserDefaults.standard.set(280.0, forKey: "burrow.desktop.sidebarWidth")
        runScenario(at: 0)
    }

    private func scenarios() -> [Scenario] {
        let preview = BurrowDesktopFixture.preview.projection

        let noTabs = BurrowDesktopProjection(
            host: preview.host,
            projects: preview.groups.map(\.project),
            workspaces: preview.groups.flatMap(\.workspaces),
            sessions: preview.sessions,
            sessionWorkspaceIDs: preview.sessionWorkspaceIDs
        )

        let all = [
            Scenario(name: "workspace-chrome", projection: preview, steps: chromeSteps()),
            Scenario(name: "branch-detail", projection: noTabs, steps: branchDetailSteps()),
            Scenario(name: "empty-welcome", projection: .empty(host: preview.host), steps: emptyWelcomeSteps()),
        ]
        if let only = ProcessInfo.processInfo.environment["CLICKPROBE_ONLY"] {
            return all.filter { $0.name == only }
        }
        return all
    }

    // MARK: - Step definitions

    private func chromeSteps() -> [Step] {
        var steps = [
            Step(
                name: "sidebar-search",
                locate: { index in
                    index.first(containing: "Search", maxX: 280)?.center
                },
                opensPalette: true
            ),
            Step(
                name: "sessions-add",
                locate: { index in
                    guard let sessionsY = index.y(of: "SESSIONS") else { return nil }
                    return index.texts.first {
                        $0.text == "+" && abs($0.y - sessionsY) < 16 && $0.x > 200
                    }?.center
                },
                expectedAction: "requestNewSession"
            ),
            Step(
                name: "session-workspace-main-open",
                locate: { index in
                    guard let sessionsY = index.y(of: "SESSIONS"),
                          let projectsY = index.y(of: "PROJECTS") else { return nil }
                    return index.first(
                        containing: "main",
                        maxX: 280,
                        minY: sessionsY + 10,
                        maxY: projectsY - 6
                    )?.center
                },
                expectedAction: "selectWorkspace"
            ),
            Step(
                name: "workspace-main-open",
                locate: { index in
                    guard let projectRow = index.first(containing: "Burrow", maxX: 280, minY: 200) else { return nil }
                    let candidates = index.all(containing: "main").filter {
                        $0.x < 280
                            && $0.y > projectRow.y + 8
                            && $0.y < projectRow.y + 56
                    }
                    return candidates.min(by: { $0.y < $1.y })?.center
                },
                expectedAction: "selectWorkspace"
            ),
            Step(
                name: "project-burrow-open",
                locate: { index in
                    index.first(containing: "Burrow", maxX: 280, minY: 200)?.center
                },
                expectedAction: "selectProject"
            ),
            Step(
                name: "tab-review-select",
                locate: { index in
                    index.first(containing: "review", minX: 300, maxY: 40)?.center
                },
                expectedAction: "selectTab",
                expectedTabID: "tab-review"
            ),
            Step(
                name: "tab-main-whitespace-select",
                // Select the first tab through its empty trailing label area,
                // not through OCR text. This catches a visually full-width tab
                // whose actual SwiftUI Button is only as wide as its title.
                locate: { _ in CGPoint(x: 385, y: 20) },
                expectedAction: "selectTab",
                expectedTabID: "tab-main"
            ),
            Step(
                name: "tab-main-select",
                locate: { index in
                    index.first(containing: "main", minX: 280, maxY: 40)?.center
                },
                expectedAction: "selectTab",
                expectedTabID: "tab-main"
            ),
            Step(
                name: "tab-main-close",
                locate: { _ in CGPoint(x: 422, y: 20) },
                candidates: { _ in
                    (0..<10).map { CGPoint(x: 395 + CGFloat($0) * 5, y: 20) }
                },
                expectedAction: "closeTab"
            ),
            Step(
                name: "tab-add",
                locate: { index in
                    index.first(containing: "+", minX: 300, maxY: 40)?.center
                        ?? CGPoint(x: 675, y: 20)
                },
                expectedAction: "requestNewSession"
            ),
            Step(
                name: "preset-claude",
                locate: { index in
                    index.first(containing: "Claude Code", minX: 280, maxY: 80)?.center
                },
                expectedAction: "launchSession"
            ),
            Step(
                name: "top-right-search",
                locate: { [windowSize] index in
                    index.first(containing: "Q", minX: 1200, maxY: 40)?.center
                        ?? CGPoint(x: windowSize.width - 15, y: 20)
                },
                opensPalette: true
            ),
            Step(
                name: "sidebar-collapse",
                locate: { _ in CGPoint(x: 94, y: 24) },
                expectedAction: "toggleSidebar"
            ),
            Step(
                name: "tabbar-expand",
                locate: { _ in CGPoint(x: 96, y: 20) },
                candidates: { _ in
                    (0..<10).map { CGPoint(x: 60 + CGFloat($0) * 10, y: 20) }
                },
                expectedAction: "toggleSidebar"
            ),
        ]
        if ProcessInfo.processInfo.environment["CLICKPROBE_SKIP_SEARCH"] == "1" {
            steps.removeAll { $0.name == "sidebar-search" || $0.name == "top-right-search" }
        }
        return steps
    }

    private func branchDetailSteps() -> [Step] {
        [
            Step(
                name: "branch-session-row",
                locate: { index in
                    let candidates = index.all(containing: "main").filter {
                        $0.x > 340 && $0.x < 720 && $0.y > 120 && $0.y < 500
                    }
                    return candidates.max(by: { $0.y < $1.y })?.center
                },
                expectedAction: "openSession"
            ),
            Step(
                name: "branch-new-session",
                locate: { index in
                    index.first(containing: "New Session", minX: 300)?.center
                },
                expectedAction: "requestNewSession"
            ),
        ]
    }

    private func emptyWelcomeSteps() -> [Step] {
        [
            Step(
                name: "welcome-add-project",
                locate: { index in
                    index.first(containing: "Add Project", minX: 300)?.center
                },
                expectedAction: "addProject"
            ),
        ]
    }

    // MARK: - Scenario runner

    private func runScenario(at index: Int) {
        let all = scenarios()
        guard index < all.count else {
            finish()
            return
        }
        let scenario = all[index]
        currentScenario = scenario
        currentSteps = []
        stepIndex = 0
        received = []
        currentNavigation = BurrowDesktopNavigationReducer.initial(for: scenario.projection)
        presentWindow(projection: scenario.projection)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let ocr = self.captureOCR()
            print("OCR \(scenario.name): \(ocr.texts.map { "\($0.text)@(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " | "))")
            self.performStep(ocr: ocr)
        }
    }

    private func presentWindow(projection: BurrowDesktopProjection) {
        window?.close()
        hosting = nil

        let root = ClickProbeRoot(
            projection: projection,
            onAction: { [weak self] action in
                guard let self else { return }
                let description = String(describing: action)
                self.received.append(description)
                print("ACTION \(description)")
            },
            onNavigation: { [weak self] navigation in
                self?.currentNavigation = navigation
            }
        )
        .environment(\.burrowForceHover, true)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .frame(width: windowSize.width, height: windowSize.height)

        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = NSRect(origin: .zero, size: windowSize)
        self.hosting = hosting

        let window = BurrowProbeWindow(
            contentRect: NSRect(origin: CGPoint(x: 100, y: 100), size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = NSColor(
            srgbRed: 21 / 255,
            green: 17 / 255,
            blue: 16 / 255,
            alpha: 1
        )
        window.level = .floating
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        window.orderFrontRegardless()
        window.acceptsMouseMovedEvents = true
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        print("AX_TRUSTED \(AXIsProcessTrusted())")
        try? "\(window.windowNumber)\n".write(
            to: URL(fileURLWithPath: "/tmp/clickprobe-window.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func performStep(ocr: OCRIndex) {
        guard let scenario = currentScenario else { return }
        guard stepIndex < scenario.steps.count else {
            completeScenario(scenario)
            return
        }
        let step = scenario.steps[stepIndex]
        let points: [CGPoint]
        if let candidates = step.candidates {
            points = candidates(ocr)
        } else if let primary = step.locate(ocr) {
            points = [primary]
        } else {
            points = []
        }
        guard !points.isEmpty else {
            print("OCR_MISS \(step.name): \(ocr.texts.map { "\($0.text)@(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " | "))")
            currentSteps.append(StepResult(
                name: step.name,
                point: Point(x: 0, y: 0),
                passed: false,
                detail: "OCR could not locate the control"
            ))
            stepIndex += 1
            performStep(ocr: captureOCR())
            return
        }

        let baseline = received.count
        var pendingPoints = points

        func runClick(at point: CGPoint) {
            self.click(at: point)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                let newActions = Array(self.received.dropFirst(baseline))
                if step.opensPalette {
                    let paletteSeen = self.paletteIsPresent()
                    let result = StepResult(
                        name: step.name,
                        point: Point(x: Double(point.x), y: Double(point.y)),
                        passed: paletteSeen,
                        detail: paletteSeen ? "palette opened" : "palette did not appear"
                    )
                    self.currentSteps.append(result)
                    self.dismissPaletteIfPresent()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                        guard let self else { return }
                        self.stepIndex += 1
                        self.performStep(ocr: self.captureOCR())
                    }
                    return
                } else if let expected = step.expectedAction {
                    let actionHit = newActions.contains { $0.hasPrefix(expected) }
                    let navigationHit = step.expectedTabID.map {
                        self.currentNavigation.selectedTabID == $0
                    } ?? true
                    let hit = actionHit && navigationHit
                    if hit {
                        self.currentSteps.append(StepResult(
                            name: step.name,
                            point: Point(x: Double(point.x), y: Double(point.y)),
                            passed: true,
                            detail: "received \(newActions.map { String($0.prefix(40)) }); selected tab \(self.currentNavigation.selectedTabID ?? "none")"
                        ))
                    } else if !pendingPoints.isEmpty {
                        let next = pendingPoints.removeFirst()
                        print("RETRY \(step.name) at \(next) (got \(newActions))")
                        runClick(at: next)
                        return
                    } else {
                        self.currentSteps.append(StepResult(
                            name: step.name,
                            point: Point(x: Double(point.x), y: Double(point.y)),
                            passed: false,
                            detail: "missing \(expected) or navigation mismatch; got \(newActions), selected tab \(self.currentNavigation.selectedTabID ?? "none")"
                        ))
                    }
                } else {
                    self.currentSteps.append(StepResult(
                        name: step.name,
                        point: Point(x: Double(point.x), y: Double(point.y)),
                        passed: true,
                        detail: "clicked"
                    ))
                }
                self.stepIndex += 1
                self.performStep(ocr: self.captureOCR())
            }
        }

        runClick(at: points[0])
    }

    private func completeScenario(_ scenario: Scenario) {
        let passed = currentSteps.allSatisfy(\.passed)
        scenarioResults.append(ScenarioResult(
            name: scenario.name,
            steps: currentSteps,
            actions: received,
            passed: passed
        ))
        print("SCENARIO \(scenario.name) \(passed ? "passed" : "FAILED")")
        for step in currentSteps where !step.passed {
            print("  FAILED \(step.name): \(step.detail)")
        }
        finish()
    }

    private func finish() {
        let passed = scenarioResults.allSatisfy(\.passed)
        let report = Report(scenarios: scenarioResults, passed: passed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/clickprobe-report.json"))
            if let name = scenarioResults.first?.name {
                try? data.write(
                    to: URL(fileURLWithPath: "/tmp/clickprobe-report-\(name).json")
                )
            }
            print("Report -> /tmp/clickprobe-report.json")
        }
        print(passed ? "ClickProbe passed." : "ClickProbe FAILED.")
        exit(passed ? 0 : 1)
    }

    private func click(at point: CGPoint) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let nsPoint = NSPoint(x: point.x, y: windowSize.height - point.y)
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: nsPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: nsPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.05,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ) else { return }
        window.sendEvent(down)
        window.sendEvent(up)
        print("CLICK \(point)")
    }

    private func paletteIsPresent() -> Bool {
        if window.attachedSheet != nil { return true }
        return NSApp.windows.contains { $0 !== window && $0.isVisible }
    }

    private func dismissPaletteIfPresent() {
        if let sheet = window.attachedSheet ?? NSApp.windows.first(where: {
            $0 !== window && $0.isVisible
        }) {
            sheet.makeKey()
            guard let escape = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheet.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            ), let escapeUp = NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + 0.02,
                windowNumber: sheet.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            ) else { return }
            sheet.sendEvent(escape)
            sheet.sendEvent(escapeUp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if let attached = self.window.attachedSheet {
                    self.window.endSheet(attached)
                }
                for candidate in NSApp.windows where candidate !== self.window && candidate.isVisible {
                    candidate.close()
                }
            }
        }
    }

    // MARK: - OCR

    private func captureOCR() -> OCRIndex {
        guard let hosting,
              let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return OCRIndex(texts: [])
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/clickprobe-render.png"))
        }
        guard let cgImage = bitmap.cgImage else { return OCRIndex(texts: []) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])

        let width = CGFloat(bitmap.pixelsWide)
        let height = CGFloat(bitmap.pixelsHigh)
        let scale = width / windowSize.width
        let texts = (request.results ?? []).compactMap { observation -> OCRText? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRText(
                text: candidate.string,
                x: box.origin.x * width / scale,
                y: (1 - box.origin.y - box.size.height) * height / scale,
                width: box.size.width * width / scale,
                height: box.size.height * height / scale
            )
        }
        let debug = texts.map { "\($0.text)@(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: "\n")
        try? debug.write(
            to: URL(fileURLWithPath: "/tmp/clickprobe-ocr.txt"),
            atomically: true,
            encoding: .utf8
        )
        return OCRIndex(texts: texts)
    }
}

private final class BurrowProbeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

let app = NSApplication.shared
let delegate = ClickProbeApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
