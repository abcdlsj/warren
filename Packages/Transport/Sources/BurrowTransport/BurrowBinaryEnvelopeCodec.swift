import Foundation
import BurrowDomain
import BurrowProtocol

extension BurrowWireCodec {
    /// Encodes Host-to-Client PTY output.
    public func encodeOutput(
        header: BinaryOutputFrameHeader,
        payload: Data
    ) throws -> [UInt8] {
        try encodeEnvelope(
            kind: .output,
            header: header,
            payload: Array(payload),
            headerPayloadLength: header.payloadLength
        )
    }

    /// Encodes Client-to-Host terminal input. The metadata is the sole input
    /// header model; its payload length is checked against both payloads.
    public func encodeInput(
        metadata: InputMetadata,
        payload: Data
    ) throws -> [UInt8] {
        try encodeEnvelope(
            kind: .input,
            header: metadata,
            payload: Array(payload),
            headerPayloadLength: metadata.payloadLength
        )
    }

    public func decodeOutputFrame(_ bytes: [UInt8]) throws -> BurrowDecodedOutputFrame {
        let envelope = try parseEnvelope(bytes)
        guard envelope.direction == .hostToClient else {
            throw BurrowWireCodecError.invalidDirection(
                expected: .hostToClient,
                received: envelope.direction
            )
        }
        guard envelope.kind == .output else {
            throw BurrowWireCodecError.kindDirectionMismatch(
                kind: envelope.kind,
                direction: envelope.direction
            )
        }
        return try decodeOutputHeader(envelope)
    }

    public func decodeInputFrame(_ bytes: [UInt8]) throws -> BurrowDecodedInputFrame {
        let envelope = try parseEnvelope(bytes)
        guard envelope.direction == .clientToHost else {
            throw BurrowWireCodecError.invalidDirection(
                expected: .clientToHost,
                received: envelope.direction
            )
        }
        guard envelope.kind == .input else {
            throw BurrowWireCodecError.kindDirectionMismatch(
                kind: envelope.kind,
                direction: envelope.direction
            )
        }
        return try decodeInputHeader(envelope)
    }

    private func encodeEnvelope<Header: Encodable>(
        kind: BinaryFrameKind,
        header: Header,
        payload: [UInt8],
        headerPayloadLength: Int
    ) throws -> [UInt8] {
        guard headerPayloadLength >= 0 else {
            throw BurrowWireCodecError.negativePayloadLength
        }
        guard payload.count == headerPayloadLength else {
            throw BurrowWireCodecError.payloadLengthMismatch(
                expected: headerPayloadLength,
                actual: payload.count
            )
        }
        guard payload.count <= maxPayload else {
            throw BurrowWireCodecError.payloadTooLarge(actual: payload.count, limit: maxPayload)
        }
        guard payload.count <= UInt32.max else {
            throw BurrowWireCodecError.integerOverflow
        }

        let headerBytes: Data
        do {
            headerBytes = try JSONEncoder().encode(header)
        } catch {
            throw BurrowWireCodecError.invalidHeaderJSON
        }
        guard headerBytes.count <= maxHeader else {
            throw BurrowWireCodecError.headerTooLarge(actual: headerBytes.count, limit: maxHeader)
        }
        guard headerBytes.count <= UInt32.max else {
            throw BurrowWireCodecError.integerOverflow
        }

        let prefixLength = Self.binaryPrefixLength
        let (withHeader, headerOverflow) = prefixLength.addingReportingOverflow(headerBytes.count)
        let (totalLength, payloadOverflow) = withHeader.addingReportingOverflow(payload.count)
        guard !headerOverflow, !payloadOverflow else {
            throw BurrowWireCodecError.integerOverflow
        }

        var result = [UInt8]()
        result.reserveCapacity(totalLength)
        result.append(contentsOf: Self.binaryMagic)
        result.append(Self.binaryVersion)
        result.append(kind.direction.rawValue)
        result.append(kind.rawValue)
        appendUInt32(UInt32(headerBytes.count), to: &result)
        appendUInt32(UInt32(payload.count), to: &result)
        result.append(contentsOf: headerBytes)
        result.append(contentsOf: payload)
        return result
    }

    func decodeOutputHeader(_ envelope: ParsedEnvelope) throws -> BurrowDecodedOutputFrame {
        let raw: RawOutputHeader
        do {
            raw = try JSONDecoder().decode(RawOutputHeader.self, from: Data(envelope.headerBytes))
        } catch {
            throw BurrowWireCodecError.invalidHeaderJSON
        }
        guard raw.payloadLength >= 0 else {
            throw BurrowWireCodecError.negativePayloadLength
        }
        guard raw.payloadLength <= maxPayload else {
            throw BurrowWireCodecError.payloadTooLarge(actual: raw.payloadLength, limit: maxPayload)
        }
        guard raw.payloadLength == envelope.payloadLength else {
            throw BurrowWireCodecError.payloadLengthMismatch(
                expected: raw.payloadLength,
                actual: envelope.payloadLength
            )
        }
        guard let header = BinaryOutputFrameHeader(
            sessionID: raw.sessionID,
            epoch: raw.epoch,
            sequence: raw.sequence,
            payloadLength: raw.payloadLength
        ) else {
            throw BurrowWireCodecError.negativePayloadLength
        }
        return BurrowDecodedOutputFrame(header: header, payload: envelope.payload)
    }

    func decodeInputHeader(_ envelope: ParsedEnvelope) throws -> BurrowDecodedInputFrame {
        let raw: RawInputHeader
        do {
            raw = try JSONDecoder().decode(RawInputHeader.self, from: Data(envelope.headerBytes))
        } catch {
            throw BurrowWireCodecError.invalidHeaderJSON
        }
        guard raw.payloadLength >= 0 else {
            throw BurrowWireCodecError.negativePayloadLength
        }
        guard raw.payloadLength <= maxPayload else {
            throw BurrowWireCodecError.payloadTooLarge(actual: raw.payloadLength, limit: maxPayload)
        }
        guard raw.payloadLength == envelope.payloadLength else {
            throw BurrowWireCodecError.payloadLengthMismatch(
                expected: raw.payloadLength,
                actual: envelope.payloadLength
            )
        }
        guard let metadata = InputMetadata(
            version: raw.version,
            sessionID: raw.sessionID,
            attachmentID: raw.attachmentID,
            payloadLength: raw.payloadLength,
            sequence: raw.sequence
        ) else {
            throw BurrowWireCodecError.negativePayloadLength
        }
        return BurrowDecodedInputFrame(metadata: metadata, payload: envelope.payload)
    }

}
