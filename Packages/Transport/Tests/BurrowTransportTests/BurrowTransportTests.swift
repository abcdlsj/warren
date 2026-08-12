import XCTest
import BurrowClientCore
import BurrowDomain
import BurrowProtocol
@testable import BurrowTransport

final class BurrowWireCodecTests: XCTestCase {
    private let sessionID = TerminalSessionID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let attachmentID = TerminalAttachmentID(rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)

    private func header(payloadLength: Int) -> BinaryOutputFrameHeader {
        BinaryOutputFrameHeader(
            sessionID: sessionID,
            epoch: 7,
            sequence: 12,
            payloadLength: payloadLength
        )!
    }

    func testControlAndBinaryRoundTrips() throws {
        let codec = BurrowWireCodec()
        let inputMetadata = try XCTUnwrap(
            InputMetadata(
                sessionID: sessionID,
                attachmentID: attachmentID,
                payloadLength: 3,
                sequence: 12
            )
        )
        let inputWire = try codec.encodeInput(metadata: inputMetadata, payload: Data([0, 1, 255]))
        let decodedInput = try codec.decodeInputFrame(inputWire)
        XCTAssertEqual(decodedInput.metadata, inputMetadata)
        XCTAssertEqual(decodedInput.payload, Data([0, 1, 255]))
        XCTAssertEqual(try codec.decodeInputFrame(inputWire), decodedInput)
        if case .input(let message) = try codec.decodeFrame(inputWire) {
            XCTAssertEqual(message, decodedInput)
        } else {
            XCTFail("input envelope must remain distinguishable")
        }

        let server = ServerControlMessage.title(TitleMessage(sessionID: sessionID, title: "shell"))
        XCTAssertEqual(server, try codec.decodeServerControl(codec.encodeControl(server)))

        let wire = try codec.encodeOutput(header: header(payloadLength: 3), payload: Data([0, 1, 255]))
        let decoded = try codec.decodeOutputFrame(wire)
        XCTAssertEqual(decoded.header, header(payloadLength: 3))
        XCTAssertEqual(decoded.payload, Data([0, 1, 255]))
        XCTAssertEqual(try codec.decodeFrame(wire), .output(decoded))
    }

    func testExactLimitsAreAcceptedAndOneBeyondIsRejected() throws {
        let payload = [UInt8](repeating: 4, count: 8)
        let frameHeader = header(payloadLength: payload.count)
        let baseline = BurrowWireCodec()
        let control = try baseline.encodeControl(ServerControlMessage.title(
            TitleMessage(sessionID: sessionID, title: "bounded")
        ))
        let binary = try baseline.encodeOutput(header: frameHeader, payload: Data(payload))
        let headerLength = readUInt32(binary, at: 7)

        XCTAssertNoThrow(try BurrowWireCodec(maxControl: control.count).decodeServerControl(control))
        XCTAssertThrowsError(try BurrowWireCodec(maxControl: control.count - 1).decodeServerControl(control))
        XCTAssertNoThrow(try BurrowWireCodec(maxHeader: Int(headerLength)).decodeOutputFrame(binary))
        XCTAssertThrowsError(try BurrowWireCodec(maxHeader: Int(headerLength) - 1).decodeOutputFrame(binary))
        XCTAssertNoThrow(try BurrowWireCodec(maxPayload: payload.count).decodeOutputFrame(binary))
        XCTAssertThrowsError(try BurrowWireCodec(maxPayload: payload.count - 1).decodeOutputFrame(binary))
    }

    func testBinaryErrorMatrixRejectsMalformedEnvelope() throws {
        let codec = BurrowWireCodec()
        let wire = try codec.encodeOutput(header: header(payloadLength: 2), payload: Data([1, 2]))

        var short = wire
        short.removeLast()
        XCTAssertThrowsError(try codec.decodeOutputFrame(short))

        var magic = wire
        magic[0] ^= 0xFF
        XCTAssertThrowsError(try codec.decodeOutputFrame(magic))

        var version = wire
        version[4] = BurrowWireCodec.binaryVersion &+ 1
        XCTAssertThrowsError(try codec.decodeOutputFrame(version))

        var trailing = wire
        trailing.append(9)
        XCTAssertThrowsError(try codec.decodeOutputFrame(trailing))

        let negative = Array("{\"sessionID\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\",\"epoch\":1,\"sequence\":2,\"payloadLength\":-1}".utf8)
        let negativeWire = makeEnvelope(
            direction: BinaryFrameDirection.hostToClient.rawValue,
            kind: BinaryFrameKind.output.rawValue,
            header: negative,
            payloadLength: 0,
            payload: []
        )
        XCTAssertThrowsError(try codec.decodeOutputFrame(negativeWire))

        XCTAssertThrowsError(try codec.decodeServerControl([0xFF]))
        XCTAssertThrowsError(try codec.decodeServerControl(Array("{} trailing".utf8)))
    }

    func testDirectionAndKindAreValidatedBeforeHeaderDecode() throws {
        let codec = BurrowWireCodec()
        let metadata = try XCTUnwrap(
            InputMetadata(sessionID: sessionID, attachmentID: attachmentID, payloadLength: 1)
        )
        let input = try codec.encodeInput(metadata: metadata, payload: Data([8]))
        XCTAssertThrowsError(try codec.decodeOutputFrame(input)) { error in
            XCTAssertEqual(
                error as? BurrowWireCodecError,
                .invalidDirection(expected: .hostToClient, received: .clientToHost)
            )
        }

        var invalidDirection = input
        invalidDirection[5] = BinaryFrameDirection.hostToClient.rawValue
        XCTAssertThrowsError(try codec.decodeInputFrame(invalidDirection)) { error in
            XCTAssertEqual(
                error as? BurrowWireCodecError,
                .kindDirectionMismatch(kind: .input, direction: .hostToClient)
            )
        }

        var invalidDirectionValue = input
        invalidDirectionValue[5] = 99
        XCTAssertThrowsError(try codec.decodeFrame(invalidDirectionValue)) { error in
            XCTAssertEqual(error as? BurrowWireCodecError, .invalidDirectionValue(received: 99))
        }

        var invalidKindValue = input
        invalidKindValue[6] = 99
        XCTAssertThrowsError(try codec.decodeFrame(invalidKindValue)) { error in
            XCTAssertEqual(error as? BurrowWireCodecError, .invalidKindValue(received: 99))
        }
    }

    func testEnvelopeLengthsAreBoundedAndMustMatchHeaderAndPayload() throws {
        let codec = BurrowWireCodec(maxHeader: 128, maxPayload: 2)
        let outputHeader = try JSONEncoder().encode(header(payloadLength: 1))
        let tooLargeHeader = makeEnvelope(
            direction: BinaryFrameDirection.hostToClient.rawValue,
            kind: BinaryFrameKind.output.rawValue,
            header: Array(outputHeader),
            payloadLength: 3,
            payload: [1, 2, 3]
        )
        XCTAssertThrowsError(try codec.decodeOutputFrame(tooLargeHeader)) { error in
            XCTAssertEqual(error as? BurrowWireCodecError, .payloadTooLarge(actual: 3, limit: 2))
        }

        let valid = try BurrowWireCodec().encodeOutput(header: header(payloadLength: 1), payload: Data([1]))
        var mismatchedEnvelopeLength = valid
        writeUInt32(2, to: &mismatchedEnvelopeLength, at: 11)
        mismatchedEnvelopeLength.append(2)
        XCTAssertThrowsError(try codec.decodeOutputFrame(mismatchedEnvelopeLength))

        var oversizedHeaderLength = valid
        writeUInt32(UInt32.max, to: &oversizedHeaderLength, at: 7)
        XCTAssertThrowsError(try BurrowWireCodec().decodeOutputFrame(oversizedHeaderLength)) { error in
            XCTAssertEqual(
                error as? BurrowWireCodecError,
                .headerTooLarge(actual: Int(UInt32.max), limit: BurrowWireCodec.defaultMaxHeader)
            )
        }
    }

    func testFuzzishMutationsNeverCrashAndPayloadLengthIsChecked() throws {
        let codec = BurrowWireCodec(maxPayload: 64)
        let wire = try codec.encodeOutput(header: header(payloadLength: 4), payload: Data([1, 2, 3, 4]))
        for index in 0..<wire.count {
            var mutation = wire
            mutation[index] ^= 0xA5
            _ = try? codec.decodeOutputFrame(mutation)
        }

        let mismatch = try codec.encodeOutput(header: header(payloadLength: 3), payload: Data([1, 2, 3]))
        var truncated = mismatch
        truncated.removeLast()
        XCTAssertThrowsError(try codec.decodeOutputFrame(truncated))
    }

    private func makeEnvelope(
        direction: UInt8,
        kind: UInt8,
        header: [UInt8],
        payloadLength: UInt32,
        payload: [UInt8]
    ) -> [UInt8] {
        var result = BurrowWireCodec.binaryMagic
        result.append(BurrowWireCodec.binaryVersion)
        result.append(direction)
        result.append(kind)
        appendUInt32(UInt32(header.count), to: &result)
        appendUInt32(payloadLength, to: &result)
        result.append(contentsOf: header)
        result.append(contentsOf: payload)
        return result
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    private func writeUInt32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }
}
