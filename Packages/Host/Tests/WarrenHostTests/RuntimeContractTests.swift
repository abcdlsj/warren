import Foundation
import XCTest
import WarrenDomain
@testable import WarrenHost

final class RuntimeContractTests: XCTestCase {
    func testInMemoryRuntimeStreamsOutputAndExitBeforeCreate() async throws {
        let runtime = InMemoryTerminalRuntime()
        let sessionID = TerminalSessionID()
        let stream = await runtime.events(for: sessionID)
        _ = try await runtime.create(
            sessionID: sessionID,
            workingDirectory: "/tmp",
            size: TerminalSize(columns: 80, rows: 24)!
        )

        let consumer = Task { () -> [TerminalRuntimeEvent] in
            var events: [TerminalRuntimeEvent] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }
        try await runtime.emitOutput(sessionID: sessionID, data: Data([0x00, 0x1B, 0xFF]))
        try await runtime.emitExit(sessionID: sessionID, exitCode: 17)

        let events = await consumer.value
        XCTAssertEqual(events, [
            .output(sessionID: sessionID, data: Data([0x00, 0x1B, 0xFF])),
            .exited(sessionID: sessionID, exitCode: 17),
        ])
        let isRunning = await runtime.exists(sessionID: sessionID)
        XCTAssertFalse(isRunning)
    }
}
