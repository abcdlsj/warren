//
//  TerminalViewState+Delegate.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

extension TerminalViewState:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceOpenURLDelegate
{
    public func terminalDidChangeTitle(_ title: String) {
        self.title = title
    }

    public func terminalDidResize(_ size: TerminalGridMetrics) {
        // Ghostty can report grid metrics synchronously from AppKit layout and
        // NSViewRepresentable updates (fitToSize -> synchronizeMetrics).
        // Writing the @Published property here publishes from inside a SwiftUI
        // view update, which SwiftUI rejects with a runtime fault and can
        // re-enter layout forever. Defer one main-actor hop so SwiftUI
        // observes the value outside the current transaction; the value is
        // unchanged.
        Task { @MainActor [weak self] in
            guard let self, self.surfaceSize != size else { return }
            self.surfaceSize = size
        }
    }

    public func terminalDidChangeFocus(_ focused: Bool) {
        // makeFirstResponder/synchronizeFocus can run inside a SwiftUI update
        // and publish isFocused mid-transaction. Same deferral as resize.
        Task { @MainActor [weak self] in
            guard let self, self.isFocused != focused else { return }
            self.isFocused = focused
        }
    }

    public func terminalDidClose(processAlive: Bool) {
        onClose?(processAlive)
    }

    public func terminalDidRingBell() {
        bellCount += 1
        lastBellAt = Date()
    }

    public func terminalDidRequestDesktopNotification(title: String, body: String) {
        lastDesktopNotificationTitle = title
        lastDesktopNotificationBody = body
        lastDesktopNotificationAt = Date()
    }

    public func terminalDidChangeWorkingDirectory(_ path: String) {
        workingDirectory = path
    }

    public func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        lastCommandExitCode = exitCode
        lastCommandDurationNanos = durationNanos
    }

    public func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        openURLHandler?(url, kind)
    }

    public func terminalDidAttachSurface(_ surface: TerminalSurface) {
        self.surface = surface
    }

    public func terminalDidDetachSurface() {
        surface = nil
    }
}
