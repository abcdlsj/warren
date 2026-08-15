import Foundation
import XCTest
@testable import WarrenNext

final class WarrenEndpointCatalogTests: XCTestCase {
    func testLoadsCLIConfigurationEndpoints() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let config = """
        {
          "current": "vps",
          "endpoints": {
            "local": {
              "name": "local",
              "url": "http://127.0.0.1:8789",
              "token": "local-token"
            },
            "vps": {
              "name": "vps",
              "url": "http://vps.example:8789",
              "token": "remote-token",
              "ssh": "root@vps.example"
            }
          }
        }
        """
        try Data(config.utf8).write(to: url)

        let catalog = WarrenEndpointCatalog.load(from: url)

        XCTAssertEqual(catalog.current, "vps")
        XCTAssertEqual(catalog.endpoints.map(\.name), ["local", "vps"])
        let vps = try XCTUnwrap(catalog.endpoints.first { $0.name == "vps" })
        XCTAssertEqual(vps.url, "http://vps.example:8789")
        XCTAssertEqual(vps.token, "remote-token")
        XCTAssertEqual(vps.ssh, "root@vps.example")
    }

    func testMissingConfigurationReturnsEmptyCatalog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalog = WarrenEndpointCatalog.load(
            from: directory.appendingPathComponent("missing.json")
        )

        XCTAssertNil(catalog.current)
        XCTAssertTrue(catalog.endpoints.isEmpty)
    }
}
