import BurrowDomain

/// The terminal's logical viewport. Pixel geometry belongs to the UI layer;
/// renderers only exchange the row and column count understood by a PTY.
public struct TerminalViewport: Codable, Hashable, Sendable {
    public let size: TerminalSize

    public init(size: TerminalSize) {
        self.size = size
    }

    public init?(columns: Int, rows: Int) {
        guard let size = TerminalSize(columns: columns, rows: rows) else {
            return nil
        }
        self.init(size: size)
    }

    public var columns: Int { size.columns }
    public var rows: Int { size.rows }
}
