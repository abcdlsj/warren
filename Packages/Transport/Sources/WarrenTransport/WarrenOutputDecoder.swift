import Foundation
import WarrenProtocol

/// Classifies one binary Host-to-Client payload before it reaches a terminal
/// renderer. The canonical daemon speaks the DENB envelope; older relays may
/// still send raw PTY bytes, which are rendered as-is.
public enum WarrenOutputDecoder {
    public enum Result: Sendable, Equatable {
        case payload(Data)
        case undecodableEnvelope
        case legacyRaw
    }

    private static let denbMagic: [UInt8] = [0x44, 0x45, 0x4E, 0x42]

    public static func decode(_ data: Data) -> Result {
        let bytes = [UInt8](data)
        if let frame = try? WarrenWireCodec().decodeOutputFrame(bytes) {
            return .payload(frame.payload)
        }
        return bytes.starts(with: denbMagic) ? .undecodableEnvelope : .legacyRaw
    }
}
