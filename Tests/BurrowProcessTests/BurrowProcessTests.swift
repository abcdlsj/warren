import Foundation
import XCTest
@testable import BurrowNext

final class BurrowProcessTests: XCTestCase {
    func testSingleInstanceLockRejectsConcurrentOwnersAndCanBeReacquired() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-instance-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("application.lock")

        var owner: BurrowSingleInstanceLock? = try XCTUnwrap(
            BurrowSingleInstanceLock(fileURL: lockURL)
        )
        XCTAssertNotNil(owner)
        for _ in 0..<5 {
            XCTAssertNil(BurrowSingleInstanceLock(fileURL: lockURL))
        }
        owner = nil
        XCTAssertNotNil(BurrowSingleInstanceLock(fileURL: lockURL))
    }
}
