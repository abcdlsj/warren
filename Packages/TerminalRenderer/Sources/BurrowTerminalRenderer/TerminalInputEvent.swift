import Foundation

/// The arrow keys understood by a terminal emulator.
public enum TerminalArrow: String, Codable, Hashable, Sendable {
    case up
    case down
    case left
    case right
}

/// Platform-neutral terminal input. A future SwiftTerm adapter is responsible
/// for consuming the resulting bytes; no UI framework is needed here.
public enum TerminalInputEvent: Hashable, Sendable {
    case text(String)
    case bytes(Data)
    case escape
    case control(Character)
    case tab
    case arrow(TerminalArrow)

    /// Encodes this event exactly as a terminal input byte sequence.
    public func encodedData() throws -> Data {
        switch self {
        case .text(let value):
            return Data(value.utf8)
        case .bytes(let value):
            return value
        case .escape:
            return Data([0x1B])
        case .control(let character):
            guard let byte = Self.controlByte(for: character) else {
                throw TerminalInputEncodingError.unsupportedControl(character)
            }
            return Data([byte])
        case .tab:
            return Data([0x09])
        case .arrow(let arrow):
            switch arrow {
            case .up: return Data([0x1B, 0x5B, 0x41])
            case .down: return Data([0x1B, 0x5B, 0x42])
            case .right: return Data([0x1B, 0x5B, 0x43])
            case .left: return Data([0x1B, 0x5B, 0x44])
            }
        }
    }

    private static func controlByte(for character: Character) -> UInt8? {
        let scalars = Array(character.unicodeScalars)
        guard scalars.count == 1, let scalar = scalars.first, scalar.value <= 0x7F else {
            return nil
        }

        let ascii = UInt8(scalar.value)
        switch ascii {
        case 0x20:
            return 0
        case 0x3F:
            return 0x7F
        case 0x40...0x5F:
            return ascii & 0x1F
        case 0x60...0x7E:
            return ascii & 0x1F
        default:
            return nil
        }
    }
}
