import Foundation
import XCTest
import WarrenDomain
import WarrenProtocol
@testable import WarrenTransport

final class WarrenOutputDecoderTests: XCTestCase {
    func testDecodesDenbEnvelopePayload() throws {
        let payload = Data("hello\r\n".utf8)
        let header = try XCTUnwrap(BinaryOutputFrameHeader(
            sessionID: TerminalSessionID(),
            epoch: 3,
            sequence: 42,
            payloadLength: payload.count
        ))
        let bytes = try WarrenWireCodec().encodeOutput(header: header, payload: payload)

        guard case .payload(let decoded) = WarrenOutputDecoder.decode(Data(bytes)) else {
            return XCTFail("expected a decoded payload")
        }
        XCTAssertEqual(decoded, payload)
    }

    func testLegacyRawBytesPassThrough() {
        let raw = Data("plain terminal bytes without an envelope".utf8)

        guard case .legacyRaw = WarrenOutputDecoder.decode(raw) else {
            return XCTFail("expected legacy raw passthrough")
        }
    }

    func testUndecodableEnvelopeIsRejected() {
        var bytes = Data("DENB".utf8)
        bytes.append(contentsOf: [1, 2, 2, 0, 0, 0, 10, 0, 0, 0, 5])
        bytes.append(Data("not-json".utf8))

        guard case .undecodableEnvelope = WarrenOutputDecoder.decode(bytes) else {
            return XCTFail("expected an undecodable envelope")
        }
    }
}
