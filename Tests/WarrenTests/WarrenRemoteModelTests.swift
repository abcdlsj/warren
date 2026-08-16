import Foundation
import XCTest
import WarrenDomain
@testable import Warren

final class WarrenRemoteModelTests: XCTestCase {
    func testRemoteAttachParametersCarryViewportWithoutClaimingFocus() throws {
        let sessionID = TerminalSessionID()
        let size = try XCTUnwrap(TerminalSize(columns: 117, rows: 38))

        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.attachParameters(sessionID: sessionID, size: size),
            [
                "id": sessionID.description,
                "focused": "false",
                "cols": "117",
                "rows": "38",
            ]
        )
    }

    func testRemoteAttachParametersRemainExplicitlyPassiveWithoutGrid() {
        let sessionID = TerminalSessionID()

        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.attachParameters(sessionID: sessionID, size: nil),
            ["id": sessionID.description, "focused": "false"]
        )
    }

    func testRemoteAttachParametersIncludeRecoveryAnchorWhenKnown() throws {
        let sessionID = TerminalSessionID()
        let size = try XCTUnwrap(TerminalSize(columns: 117, rows: 38))
        let anchor = TerminalOutputAnchor(epoch: 3, sequence: 4096)

        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.attachParameters(
                sessionID: sessionID,
                size: size,
                anchor: anchor
            ),
            [
                "id": sessionID.description,
                "focused": "false",
                "cols": "117",
                "rows": "38",
                "epoch": "3",
                "sequence": "4096",
            ]
        )
    }

    func testRemoteRosterAttachesInitialTabAndDoesNotDuplicateMountedSurface() {
        XCTAssertTrue(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: nil,
            nextTabID: "tab-1",
            mountedSurfaceCount: 0
        ))
        XCTAssertFalse(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: "tab-1",
            nextTabID: "tab-1",
            mountedSurfaceCount: 1
        ))
        XCTAssertTrue(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: "tab-1",
            nextTabID: "tab-2",
            mountedSurfaceCount: 1
        ))
        XCTAssertFalse(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: nil,
            nextTabID: nil,
            mountedSurfaceCount: 0
        ))
    }

    func testRemoteRosterReattachesSameTabAfterTransportReset() {
        XCTAssertTrue(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: "tab-1",
            nextTabID: "tab-1",
            mountedSurfaceCount: 0
        ))
    }

    func testReconnectDelayBacksOffExponentiallyAndCapsAtThirtySeconds() {
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 0), 500)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 1), 1_000)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 2), 2_000)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 6), 30_000)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 99), 30_000)
    }

    func testStaleSessionDeleteErrorIsBenign() {
        let sessionID = TerminalSessionID()

        XCTAssertTrue(WarrenRemoteApplicationModel.isSessionAlreadyClosed(
            NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "session not found: \(sessionID)",
            ]),
            sessionID: sessionID
        ))
        XCTAssertFalse(WarrenRemoteApplicationModel.isSessionAlreadyClosed(
            NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "session not found: another-id",
            ]),
            sessionID: sessionID
        ))
        XCTAssertFalse(WarrenRemoteApplicationModel.isSessionAlreadyClosed(
            NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "tmux kill failed",
            ]),
            sessionID: sessionID
        ))
    }

    func testLosslessAsyncBufferBackpressuresAndPreservesOrder() async throws {
        let buffer = WarrenLosslessAsyncBuffer<Int>(capacity: 2)
        let progress = SendProgress()
        let producer = Task {
            for value in 0..<100 {
                guard await buffer.send(value) else { return false }
                await progress.recordSend()
            }
            return true
        }

        await progress.waitForSends(2)
        try await Task.sleep(for: .milliseconds(2))
        let sentBeforeConsumption = await progress.sentCount
        XCTAssertEqual(sentBeforeConsumption, 2)

        var iterator = buffer.stream.makeAsyncIterator()
        var received: [Int] = []
        for _ in 0..<100 {
            let next = await iterator.next()
            received.append(try XCTUnwrap(next))
        }
        let completed = await producer.value
        XCTAssertTrue(completed)
        buffer.finish()
        XCTAssertEqual(received, Array(0..<100))
    }

    func testTerminalOutputBufferDeduplicatesOverlapAndKeepsSequenceGaps() {
        var buffer = WarrenTerminalOutputBuffer()
        buffer.reset(epoch: 7, sequence: 0)
        buffer.append(epoch: 7, sequence: 0, payload: Data("abcdef".utf8))
        buffer.append(epoch: 7, sequence: 0, payload: Data("abcdef".utf8))
        buffer.append(epoch: 7, sequence: 3, payload: Data("defghi".utf8))

        var slices: [WarrenTerminalOutputSlice] = []
        while let slice = buffer.take(maxBytes: 4) { slices.append(slice) }
        XCTAssertEqual(slices.map(\.sequence), [0, 4, 6])
        XCTAssertEqual(
            Data(slices.flatMap { $0.payload }),
            Data("abcdefghi".utf8)
        )
        XCTAssertEqual(buffer.enqueuedSequence, 9)

        buffer.append(epoch: 8, sequence: 100, payload: Data("xyz".utf8))
        XCTAssertEqual(buffer.take(maxBytes: 8), WarrenTerminalOutputSlice(
            epoch: 8,
            sequence: 100,
            payload: Data("xyz".utf8)
        ))
    }
}

private actor SendProgress {
    private(set) var sentCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func recordSend() {
        sentCount += 1
        let ready = waiters.filter { sentCount >= $0.count }
        waiters.removeAll { sentCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForSends(_ count: Int) async {
        guard sentCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}
