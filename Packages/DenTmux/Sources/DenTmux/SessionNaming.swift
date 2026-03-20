import Foundation

/// Central rules for naming Den-managed tmux sessions.
public enum SessionNaming {

    public static let separator = "/"

    private static let strippablePrefixes = [
        "feature/", "feat/", "fix/", "bugfix/", "hotfix/", "release/",
    ]

    public static func slugify(_ input: String) -> String {
        let lowered = input.lowercased()
        var result = ""
        var lastWasHyphen = false
        // Session names need to stay shell-safe and tmux-friendly.
        for char in lowered {
            if char.isLetter || char.isNumber {
                result.append(char)
                lastWasHyphen = false
            } else {
                if !lastWasHyphen && !result.isEmpty {
                    result.append("-")
                    lastWasHyphen = true
                }
            }
        }
        if result.hasSuffix("-") {
            result.removeLast()
        }
        return result
    }

    public static func stripBranchPrefix(_ branch: String) -> String {
        let lower = branch.lowercased()
        for prefix in strippablePrefixes {
            // Drop noisy workflow prefixes so session titles stay readable.
            if lower.hasPrefix(prefix) {
                return String(branch.dropFirst(prefix.count))
            }
        }
        return branch
    }

    public static func sessionName(projectShortName: String, worktree: String) -> String {
        let branch = stripBranchPrefix(worktree)
        return "\(projectShortName)\(separator)\(slugify(branch))"
    }

    public static func isDenSession(_ name: String) -> Bool {
        name.contains(separator) && parse(name) != nil
    }

    public static func parse(_ name: String) -> (projectShortName: String, branchSlug: String)? {
        guard let slashIndex = name.firstIndex(of: "/") else { return nil }
        let project = String(name[name.startIndex..<slashIndex])
        let branch = String(name[name.index(after: slashIndex)...])
        guard !project.isEmpty, !branch.isEmpty else { return nil }
        return (projectShortName: project, branchSlug: branch)
    }
}
