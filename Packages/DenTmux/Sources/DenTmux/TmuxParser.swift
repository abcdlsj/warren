import Foundation

public enum TmuxParser {

    public static let delimiter = "\t"

    // MARK: - Format Strings

    public static let sessionFormat: String = [
        "#{session_id}",
        "#{session_name}",
        "#{session_windows}",
        "#{session_attached}",
    ].joined(separator: delimiter)

    public static let windowFormat: String = [
        "#{window_id}",
        "#{window_index}",
        "#{window_name}",
        "#{window_active}",
        "#{pane_current_path}",
    ].joined(separator: delimiter)

    public static let paneFormat: String = [
        "#{pane_id}",
        "#{pane_tty}",
        "#{pane_active}",
        "#{pane_current_path}",
        "#{pane_title}",
        "#{pane_activity}",
        "#{pane_current_command}",
        "#{pane_start_time}",
    ].joined(separator: delimiter)

    // MARK: - Parsing

    public static func parseSessions(_ output: String) -> [TmuxSession] {
        parseLines(output).compactMap { fields in
            guard fields.count >= 4 else { return nil }
            return TmuxSession(
                sessionId: fields[0],
                name: fields[1],
                windowCount: Int(fields[2]) ?? 0,
                isAttached: fields[3] == "1"
            )
        }
    }

    public static func parseWindows(_ output: String) -> [TmuxWindow] {
        parseLines(output).compactMap { fields in
            guard fields.count >= 5 else { return nil }
            return TmuxWindow(
                windowId: fields[0],
                windowIndex: Int(fields[1]) ?? 0,
                name: fields[2],
                isActive: fields[3] == "1",
                currentPath: fields[4].isEmpty ? nil : fields[4]
            )
        }
    }

    public static func parsePanes(_ output: String) -> [TmuxPane] {
        parseLines(output).compactMap { fields in
            guard fields.count >= 5 else { return nil }
            return TmuxPane(
                paneId: fields[0],
                tty: fields[1].isEmpty ? nil : fields[1],
                isActive: fields[2] == "1",
                currentPath: fields[3].isEmpty ? nil : fields[3],
                title: fields[4].isEmpty ? nil : fields[4],
                lastActivity: fields.count >= 6 ? Double(fields[5]) : nil,
                currentCommand: fields.count >= 7 && !fields[6].isEmpty ? fields[6] : nil,
                startTime: fields.count >= 8 ? Double(fields[7]) : nil
            )
        }
    }

    // MARK: - Private

    private static func parseLines(_ output: String) -> [[String]] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                String(line).components(separatedBy: delimiter)
            }
    }
}
