import Foundation

public enum TerminalSemanticColor: Codable, Hashable, Sendable {
    case indexed(Int)
    case rgb(red: Int, green: Int, blue: Int)
}

public struct TerminalSemanticStyle: Codable, Hashable, Sendable {
    public var foreground: TerminalSemanticColor?
    public var background: TerminalSemanticColor?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool

    public init(
        foreground: TerminalSemanticColor? = nil,
        background: TerminalSemanticColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }
}

public struct TerminalSemanticRun: Codable, Hashable, Sendable {
    public let text: String
    public let style: TerminalSemanticStyle
}

public struct TerminalSemanticSnapshot: Codable, Hashable, Sendable {
    public let plainText: String
    public let runs: [TerminalSemanticRun]
    public let containsStyledText: Bool
}

/// Privacy-safe ANSI state observer used by the headless acceptance suite.
/// It retains no input and receives Host output only at the same boundary as
/// Ghostty. Cursor/grid semantics remain Ghostty-owned.
final class TerminalANSIObserver {
    private let lock = NSLock()
    private var style = TerminalSemanticStyle()
    private var runs: [TerminalSemanticRun] = []
    private var pendingText = ""
    private var pendingEscape = Data()

    func receive(_ data: Data) {
        lock.withLock {
            let bytes = Array(pendingEscape) + Array(data)
            pendingEscape.removeAll(keepingCapacity: true)
            var index = 0
            while index < bytes.count {
                guard bytes[index] == 0x1b else {
                    let start = index
                    while index < bytes.count, bytes[index] != 0x1b { index += 1 }
                    appendText(Data(bytes[start..<index]))
                    continue
                }
                guard index + 1 < bytes.count else {
                    pendingEscape.append(bytes[index])
                    break
                }
                guard bytes[index + 1] == 0x5b else {
                    index += 2
                    continue
                }
                var end = index + 2
                while end < bytes.count,
                      !(0x40...0x7e).contains(bytes[end]) { end += 1 }
                guard end < bytes.count else {
                    pendingEscape.append(contentsOf: bytes[index...])
                    break
                }
                if bytes[end] == 0x6d {
                    flushText()
                    applySGR(Data(bytes[(index + 2)..<end]))
                }
                index = end + 1
            }
        }
    }

    func snapshot() -> TerminalSemanticSnapshot {
        lock.withLock {
            flushText()
            let plainText = runs.map(\.text).joined()
            return TerminalSemanticSnapshot(
                plainText: plainText,
                runs: runs,
                containsStyledText: runs.contains { $0.style != TerminalSemanticStyle() }
            )
        }
    }

    private func appendText(_ data: Data) {
        pendingText += String(decoding: data, as: UTF8.self)
    }

    private func flushText() {
        guard !pendingText.isEmpty else { return }
        if let last = runs.last, last.style == style {
            runs[runs.count - 1] = TerminalSemanticRun(
                text: last.text + pendingText,
                style: style
            )
        } else {
            runs.append(TerminalSemanticRun(text: pendingText, style: style))
        }
        pendingText = ""
    }

    private func applySGR(_ data: Data) {
        let raw = String(decoding: data, as: UTF8.self)
        let parameters = raw.isEmpty ? [0] : raw.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        var index = 0
        while index < parameters.count {
            let value = parameters[index]
            switch value {
            case 0: style = TerminalSemanticStyle()
            case 1: style.bold = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22: style.bold = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 30...37: style.foreground = .indexed(value - 30)
            case 90...97: style.foreground = .indexed(value - 90 + 8)
            case 39: style.foreground = nil
            case 40...47: style.background = .indexed(value - 40)
            case 100...107: style.background = .indexed(value - 100 + 8)
            case 49: style.background = nil
            case 38, 48:
                let isForeground = value == 38
                if index + 2 < parameters.count, parameters[index + 1] == 5 {
                    let color = TerminalSemanticColor.indexed(parameters[index + 2])
                    if isForeground { style.foreground = color } else { style.background = color }
                    index += 2
                } else if index + 4 < parameters.count, parameters[index + 1] == 2 {
                    let color = TerminalSemanticColor.rgb(
                        red: parameters[index + 2],
                        green: parameters[index + 3],
                        blue: parameters[index + 4]
                    )
                    if isForeground { style.foreground = color } else { style.background = color }
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }
}
