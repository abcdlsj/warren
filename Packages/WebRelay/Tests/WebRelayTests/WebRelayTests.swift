import XCTest
import Foundation
import BurrowApplication
import BurrowDomain
import BurrowHost
import BurrowStateStore
@testable import WebRelay

final class WebRelayTests: XCTestCase {
    @MainActor
    func testWebPageResourceIsBundled() {
        XCTAssertNotNil(WebRelayServer.webPageURL)
        XCTAssertNotNil(WebRelayServer.webPageURLWithToken)
        XCTAssertNotNil(WebRelayServer.webPageURL(host: "abc.trycloudflare.com"))
        let dataURL = WebRelayServer.webPageDataURL(host: "abc.trycloudflare.com")
        XCTAssertTrue(dataURL?.absoluteString.hasPrefix("data:text/html;base64,") == true)
    }

    @MainActor
    func testTunnelURLParsing() {
        let output = """
        INF Registered tunnel connection
        https://loud-words-trycloudflare-com.trycloudflare.com
        """
        XCTAssertEqual(
            WebRelayServer.parseTunnelURL(from: output)?.absoluteString,
            "https://loud-words-trycloudflare-com.trycloudflare.com"
        )
        let tailscaleJSON = """
        {"TCP":{"443":{"HTTPS":true}},"Web":{"bilibili.tail3d6e0.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8788"}}}}}
        """
        XCTAssertEqual(
            WebRelayServer.parseTailscaleURL(from: tailscaleJSON)?.absoluteString,
            "https://bilibili.tail3d6e0.ts.net/"
        )
        let funnelJSON = """
        {"TCP":{"443":{"HTTPS":true}},"Funnel":{"bilibili.tail3d6e0.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8788"}}}}}
        """
        XCTAssertEqual(
            WebRelayServer.parseTailscaleURL(from: funnelJSON)?.absoluteString,
            "https://bilibili.tail3d6e0.ts.net/"
        )
    }

}
