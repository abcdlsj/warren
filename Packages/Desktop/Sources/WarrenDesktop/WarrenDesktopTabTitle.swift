import Foundation
import WarrenClientCore
import WarrenDomain

/// Tab title derivation matching Superset's GroupStrip: an interactive shell
/// reads as its directory so multiple workspaces are recognizable at a glance,
/// while a real running process (codex, claude, dev servers, ...) is shown
/// alongside the directory.
enum WarrenDesktopTabTitle {
    private static let shellProcessNames: Set<String> = [
        "zsh", "bash", "sh", "dash", "fish", "ksh", "csh", "tcsh",
        "pwsh", "powershell", "cmd", "nu", "elvish", "xonsh", "oil", "osh",
    ]

    static func displayTitle(
        tab: ClientTab,
        session: WarrenDesktopSession?,
        workspace: Workspace?
    ) -> String {
        let directory = directoryName(tab: tab, session: session, workspace: workspace)
        let command = resolvedCommand(tab: tab, session: session)
        if command.isEmpty {
            return directory
        }
        return "\(command) — \(directory)"
    }

    static func directoryName(
        tab: ClientTab,
        session: WarrenDesktopSession?,
        workspace: Workspace?
    ) -> String {
        let path = session?.workingDirectory.isEmpty == false
            ? session!.workingDirectory
            : (workspace?.path ?? "")
        guard !path.isEmpty else { return tab.title }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? tab.title : name
    }

    private static func resolvedCommand(
        tab: ClientTab,
        session: WarrenDesktopSession?
    ) -> String {
        let process = session?.runtimeProcess
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !process.isEmpty, !shellProcessNames.contains(process) {
            return process
        }
        if session == nil || process.isEmpty {
            return tab.kind == .shell ? "" : tab.kind.displayName
        }
        return ""
    }
}
