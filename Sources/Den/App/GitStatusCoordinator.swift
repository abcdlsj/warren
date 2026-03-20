import Foundation
import DenCore
import DenGit

@MainActor
final class GitStatusCoordinator {

    let gitBackend: GitBackend

    init(gitBackend: GitBackend) {
        self.gitBackend = gitBackend
    }

    func pollAll(worktrees: [Worktree]) async -> [UUID: GitStatusInfo] {
        let activeWorktrees = worktrees.filter { $0.tmuxSessionName != nil }
        guard !activeWorktrees.isEmpty else { return [:] }

        let backend = self.gitBackend
        return await withTaskGroup(of: (UUID, GitStatusInfo?).self) { group in
            for worktree in activeWorktrees {
                group.addTask {
                    do {
                        let status = try await backend.status(worktreePath: worktree.path)
                        return (worktree.id, status)
                    } catch {
                        return (worktree.id, nil)
                    }
                }
            }

            var results: [UUID: GitStatusInfo] = [:]
            for await (id, status) in group {
                if let status {
                    results[id] = status
                }
            }
            return results
        }
    }
}
