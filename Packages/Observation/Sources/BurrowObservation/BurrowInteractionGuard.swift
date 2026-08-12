import AppKit
import Foundation

public struct BurrowInteractionSnapshot: Codable, Equatable, Sendable {
    public let frontmostApplicationPID: Int32?
    public let mouseX: Double
    public let mouseY: Double

    public init(frontmostApplicationPID: Int32?, mouseX: Double, mouseY: Double) {
        self.frontmostApplicationPID = frontmostApplicationPID
        self.mouseX = mouseX
        self.mouseY = mouseY
    }
}

public enum BurrowInteractionGuardError: Error, Equatable {
    case frontmostApplicationChanged(expected: Int32?, actual: Int32?)
    case mouseMoved(expectedX: Double, expectedY: Double, actualX: Double, actualY: Double)
}

@MainActor
public enum BurrowInteractionGuard {
    public static func capture() -> BurrowInteractionSnapshot {
        let point = NSEvent.mouseLocation
        return BurrowInteractionSnapshot(
            frontmostApplicationPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            mouseX: point.x,
            mouseY: point.y
        )
    }

    public static func verifyUnchanged(
        from expected: BurrowInteractionSnapshot,
        to actual: BurrowInteractionSnapshot
    ) throws {
        guard expected.frontmostApplicationPID == actual.frontmostApplicationPID else {
            throw BurrowInteractionGuardError.frontmostApplicationChanged(
                expected: expected.frontmostApplicationPID,
                actual: actual.frontmostApplicationPID
            )
        }
        guard expected.mouseX == actual.mouseX, expected.mouseY == actual.mouseY else {
            throw BurrowInteractionGuardError.mouseMoved(
                expectedX: expected.mouseX,
                expectedY: expected.mouseY,
                actualX: actual.mouseX,
                actualY: actual.mouseY
            )
        }
    }
}
