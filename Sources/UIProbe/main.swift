import AppKit
import BurrowDesktop
import BurrowObservation
import Foundation
import SwiftUI

private struct UIProbeReport: Codable {
    let width: Int
    let height: Int
    let interactionBefore: BurrowInteractionSnapshot
    let interactionAfter: BurrowInteractionSnapshot
    let semanticNodeCount: Int
    let observedActions: [String]
    let invariantViolations: [String]
}

private enum UIProbeError: Error, CustomStringConvertible {
    case noSemanticNodes

    var description: String {
        switch self {
        case .noSemanticNodes:
            "The real desktop view emitted no semantic UI nodes."
        }
    }
}

private struct ProbeTerminalSurface: View {
    let context: BurrowDesktopTerminalContext

    var body: some View {
        Text("probe:\(context.tab.id)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .foregroundStyle(Color.green)
            .font(.system(size: 12, design: .monospaced))
            .burrowSemanticElement(
                id: "terminal.\(context.tab.id)",
                role: .terminal,
                label: "Terminal \(context.tab.title)"
            )
    }
}

/// A non-visual, non-activating UI observer.
///
/// It mounts the production SwiftUI tree in an in-process hosting view, reads
/// the semantic contract emitted by that tree, and verifies that neither the
/// user's frontmost application nor the global mouse position changed. It
/// never creates a bitmap, screenshot, CGEvent, or key window.
@MainActor
private enum UIProbe {
    static func run() throws {
        let width: CGFloat = 1_280
        let height: CGFloat = 800
        let outputDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_ARTIFACT_DIR"]
                ?? "/tmp/burrow-observation/ui-probe",
            isDirectory: true
        )
        let recorder = BurrowSemanticRecorder()
        let before = BurrowInteractionGuard.capture()
        var actions: [BurrowDesktopAction] = []

        let root = BurrowDesktopRoot(
            projection: BurrowDesktopFixture.preview.projection,
            actions: BurrowDesktopActions { actions.append($0) }
        ) { context in
            ProbeTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.burrowForceHover, true)
        .environment(\.burrowSemanticRecorder, recorder)
        .frame(width: width, height: height)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hostingView.layoutSubtreeIfNeeded()

        let initialWorkspace = BurrowDesktopFixture.preview.projection.groups[0].workspaces[0]
        let initialProject = BurrowDesktopFixture.preview.projection.groups[0].project
        let collapsedSnapshot = recorder.snapshot()
        guard !collapsedSnapshot.nodes.isEmpty else { throw UIProbeError.noSemanticNodes }
        guard collapsedSnapshot.nodes.first(where: {
            $0.id == "project.\(initialProject.id.description)"
        })?.value == "Collapsed" else {
            throw NSError(
                domain: "Burrow.UIProbe",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Project rows must be collapsed initially."]
            )
        }
        try recorder.perform(
            .press,
            on: "project.\(initialProject.id.description)"
        )
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        try recorder.perform(
            .press,
            on: "workspace.project-list.\(initialWorkspace.id.description)"
        )
        try recorder.perform(
            .press,
            on: "project.\(initialProject.id.description).new-workspace"
        )
        let snapshot = recorder.snapshot()

        let after = BurrowInteractionGuard.capture()
        var violations: [String] = []
        do {
            try BurrowInteractionGuard.verifyUnchanged(from: before, to: after)
        } catch {
            violations.append(String(describing: error))
        }
        let duplicateIDs = Dictionary(grouping: snapshot.nodes, by: \.id)
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        if !duplicateIDs.isEmpty {
            violations.append("Duplicate semantic IDs: \(duplicateIDs.joined(separator: ", "))")
        }
        let invalidFrames = snapshot.nodes.filter {
            $0.frame.width <= 0 || $0.frame.height <= 0
        }.map(\.id)
        if !invalidFrames.isEmpty {
            violations.append("Non-positive semantic frames: \(invalidFrames.joined(separator: ", "))")
        }
        let undersizedSidebarRows = snapshot.nodes.filter {
            if $0.id.hasPrefix("project.") && !$0.id.hasSuffix(".new-workspace") {
                return $0.frame.width < 250 || $0.frame.height < 28
            }
            if $0.id.hasPrefix("workspace.project-list.") {
                return $0.frame.width < 240 || $0.frame.height < 26
            }
            return false
        }.map(\.id)
        if !undersizedSidebarRows.isEmpty {
            violations.append(
                "Sidebar navigation targets do not cover their rows: " +
                    undersizedSidebarRows.joined(separator: ", ")
            )
        }

        try BurrowArtifactWriter.writeJSON(
            snapshot,
            to: outputDirectory.appendingPathComponent("semantic-ui.json")
        )
        let report = UIProbeReport(
            width: Int(width),
            height: Int(height),
            interactionBefore: before,
            interactionAfter: after,
            semanticNodeCount: snapshot.nodes.count,
            observedActions: actions.map(String.init(describing:)),
            invariantViolations: violations
        )
        try BurrowArtifactWriter.writeJSON(
            report,
            to: outputDirectory.appendingPathComponent("result.json")
        )

        guard violations.isEmpty else {
            throw NSError(
                domain: "Burrow.UIProbe",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: violations.joined(separator: "\n")]
            )
        }
        print("semantic UI OK: \(snapshot.nodes.count) nodes -> \(outputDirectory.path)")
    }
}

try UIProbe.run()
