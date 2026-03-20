import Foundation

/// Parser for `git worktree list --porcelain`.
public enum GitWorktreeParser {

    public static func parse(_ output: String) -> [GitWorktreeInfo] {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let blocks = splitIntoBlocks(output)

        return blocks.compactMap { block in
            parseBlock(block)
        }
    }

    // MARK: - Private

    private static func splitIntoBlocks(_ output: String) -> [[String]] {
        var blocks: [[String]] = []
        var currentBlock: [String] = []

        // The porcelain format emits a blank line between worktree records.
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !currentBlock.isEmpty {
                    blocks.append(currentBlock)
                    currentBlock = []
                }
            } else {
                currentBlock.append(trimmed)
            }
        }

        if !currentBlock.isEmpty {
            blocks.append(currentBlock)
        }

        return blocks
    }

    private static func parseBlock(_ lines: [String]) -> GitWorktreeInfo? {
        var path: String?
        var head: String?
        var branch: String?
        var isDetached = false
        var isBare = false

        for line in lines {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                branch = String(line.dropFirst("branch ".count))
            } else if line == "detached" {
                isDetached = true
            } else if line == "bare" {
                isBare = true
            }
        }

        guard let path, let head else {
            return nil
        }

        return GitWorktreeInfo(
            path: path,
            head: head,
            branch: branch,
            isDetached: isDetached,
            isBare: isBare
        )
    }
}
