import Foundation

public enum GitStatusParser {

    public static func parse(_ output: String) -> GitStatusInfo {
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var stagedCount = 0
        var modifiedCount = 0
        var untrackedCount = 0

        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("# branch.head ") {
                branch = String(trimmed.dropFirst("# branch.head ".count))
            } else if trimmed.hasPrefix("# branch.upstream ") {
                upstream = String(trimmed.dropFirst("# branch.upstream ".count))
            } else if trimmed.hasPrefix("# branch.ab ") {
                let abPart = String(trimmed.dropFirst("# branch.ab ".count))
                parseAheadBehind(abPart, ahead: &ahead, behind: &behind)
            } else if trimmed.hasPrefix("1 ") || trimmed.hasPrefix("2 ") {
                parseChangedEntry(trimmed, staged: &stagedCount, modified: &modifiedCount)
            } else if trimmed.hasPrefix("u ") {
                stagedCount += 1
                modifiedCount += 1
            } else if trimmed.hasPrefix("? ") {
                untrackedCount += 1
            }
        }

        return GitStatusInfo(
            untrackedCount: untrackedCount,
            modifiedCount: modifiedCount,
            stagedCount: stagedCount,
            ahead: ahead,
            behind: behind,
            branch: branch,
            upstream: upstream
        )
    }

    // MARK: - Private

    private static func parseAheadBehind(
        _ value: String,
        ahead: inout Int,
        behind: inout Int
    ) {
        let parts = value.split(separator: " ")
        for part in parts {
            if part.hasPrefix("+"), let n = Int(part.dropFirst()) {
                ahead = n
            } else if part.hasPrefix("-"), let n = Int(part.dropFirst()) {
                behind = n
            }
        }
    }

    private static func parseChangedEntry(
        _ line: String,
        staged: inout Int,
        modified: inout Int
    ) {
        guard line.count >= 4 else { return }

        let startIndex = line.index(line.startIndex, offsetBy: 2)
        let x = line[startIndex]
        let y = line[line.index(after: startIndex)]

        if x != "." {
            staged += 1
        }
        if y != "." {
            modified += 1
        }
    }
}
