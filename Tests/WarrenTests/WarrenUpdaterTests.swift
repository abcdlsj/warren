import Foundation
import XCTest
@testable import Warren

final class WarrenUpdaterTests: XCTestCase {
    func testSemanticVersionsCompareNumericAndPrereleaseParts() throws {
        let version09 = try XCTUnwrap(WarrenVersion("0.9.0"))
        let version010 = try XCTUnwrap(WarrenVersion("0.10.0"))
        let release = try XCTUnwrap(WarrenVersion("1.0.0"))
        let candidate = try XCTUnwrap(WarrenVersion("1.0.0-rc.1"))
        let nextCandidate = try XCTUnwrap(WarrenVersion("1.0.0-rc.2"))

        XCTAssertTrue(version010 > version09)
        XCTAssertTrue(release > candidate)
        XCTAssertTrue(nextCandidate > candidate)
        XCTAssertEqual(WarrenVersion("v1.2"), WarrenVersion("1.2.0"))
    }

    func testSemanticVersionRejectsMalformedValues() {
        XCTAssertNil(WarrenVersion(""))
        XCTAssertNil(WarrenVersion("warren"))
        XCTAssertNil(WarrenVersion("1.2.3.4"))
        XCTAssertNil(WarrenVersion("1.2-"))
    }

    func testReleaseSelectsOnlyTrustedWarrenZipAsset() throws {
        let release = try JSONDecoder().decode(
            WarrenRelease.self,
            from: Data(
                """
                {
                  "tag_name": "v0.5.0",
                  "html_url": "https://github.com/abcdlsj/warren/releases/tag/v0.5.0",
                  "body": "Update",
                  "assets": [
                    {
                      "name": "checksums.txt",
                      "browser_download_url": "https://github.com/abcdlsj/warren/releases/download/v0.5.0/checksums.txt",
                      "size": 12
                    },
                    {
                      "name": "Warren-0.5.0.zip",
                      "browser_download_url": "https://github.com/abcdlsj/warren/releases/download/v0.5.0/Warren-0.5.0.zip",
                      "size": 42
                    }
                  ]
                }
                """.utf8
            )
        )

        XCTAssertEqual(release.displayVersion, "v0.5.0")
        XCTAssertEqual(release.applicationAsset?.name, "Warren-0.5.0.zip")
        XCTAssertTrue(release.isInstallable)
    }

    @MainActor
    func testAutomaticCheckCadenceUsesLastSuccessfulCheckDate() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let now = Date(timeIntervalSince1970: 10_000)
        let updater = WarrenUpdater(
            currentVersion: WarrenVersion("0.4.0"),
            userDefaults: defaults,
            now: { now },
            cacheDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )

        XCTAssertTrue(updater.shouldCheckAutomatically)
        defaults.set(now, forKey: WarrenUpdater.lastCheckDateKey)
        XCTAssertFalse(updater.shouldCheckAutomatically)
    }
}
