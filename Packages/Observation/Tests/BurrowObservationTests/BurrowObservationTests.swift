import XCTest
@testable import BurrowObservation

final class BurrowObservationTests: XCTestCase {
    func testLogAssignsMonotonicSequenceAndRetainsCapacity() async {
        let log = BurrowObservationLog(capacity: 2, clock: { 42 })
        _ = await log.record(kind: .command, name: "one")
        _ = await log.record(kind: .resource, name: "two")
        _ = await log.record(kind: .runtime, name: "three")

        let events = await log.events()
        XCTAssertEqual(events.map(\.sequence), [1, 2])
        XCTAssertEqual(events.map(\.name), ["two", "three"])
        XCTAssertEqual(events.map(\.timestampNanoseconds), [42, 42])
        let tail = await log.events(since: 2)
        XCTAssertEqual(tail.map(\.name), ["three"])
    }

    func testSemanticSnapshotSortsAndFindsNodes() {
        let frame = BurrowSemanticRect(x: 1, y: 2, width: 3, height: 4)
        let snapshot = BurrowSemanticSnapshot(
            capturedAtNanoseconds: 1,
            nodes: [
                BurrowSemanticNode(id: "z", role: .button, label: "Z", frame: frame),
                BurrowSemanticNode(id: "a", role: .tab, label: "A", frame: frame),
            ]
        )

        XCTAssertEqual(snapshot.nodes.map(\.id), ["a", "z"])
        XCTAssertEqual(snapshot.node(id: "z")?.label, "Z")
    }

    func testSemanticSnapshotPreservesDuplicateIDsForInvariantChecks() {
        let frame = BurrowSemanticRect(x: 0, y: 0, width: 1, height: 1)
        let snapshot = BurrowSemanticSnapshot(
            capturedAtNanoseconds: 1,
            nodes: [
                BurrowSemanticNode(id: "duplicate", role: .button, label: "One", frame: frame),
                BurrowSemanticNode(id: "duplicate", role: .button, label: "Two", frame: frame),
            ]
        )

        XCTAssertEqual(snapshot.nodes.count, 2)
    }

    @MainActor
    func testRecorderPerformsRegisteredTypedAction() throws {
        let recorder = BurrowSemanticRecorder()
        var presses = 0
        recorder.registerAction(id: "button", action: { presses += 1 })

        try recorder.perform(.press, on: "button")

        XCTAssertEqual(presses, 1)
    }

    @MainActor
    func testInteractionGuardDetectsFocusAndMouseChanges() {
        let initial = BurrowInteractionSnapshot(
            frontmostApplicationPID: 1,
            mouseX: 10,
            mouseY: 20
        )
        XCTAssertNoThrow(try BurrowInteractionGuard.verifyUnchanged(from: initial, to: initial))
        XCTAssertThrowsError(
            try BurrowInteractionGuard.verifyUnchanged(
                from: initial,
                to: BurrowInteractionSnapshot(
                    frontmostApplicationPID: 2,
                    mouseX: 10,
                    mouseY: 20
                )
            )
        )
        XCTAssertThrowsError(
            try BurrowInteractionGuard.verifyUnchanged(
                from: initial,
                to: BurrowInteractionSnapshot(
                    frontmostApplicationPID: 1,
                    mouseX: 11,
                    mouseY: 20
                )
            )
        )
    }
}
