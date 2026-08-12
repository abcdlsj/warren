import Foundation

extension TmuxRuntime {
    /// Stops adapter observation while leaving tmux Sessions untouched.
    /// This is used when the Host process is shutting down or replacing its
    /// runtime adapter; it deliberately does not call `kill-session`.
    public func shutdown() {
        for tail in writeTails.values { tail.completion.cancel() }
        writeTails.removeAll()
        lifecycleMonitorTask?.cancel()
        lifecycleMonitorTask = nil
        for managed in sessions.values {
            managed.watcher.cancel()
        }
        // Drop only adapter observation state. The tmux sessions remain
        // discoverable by a new adapter through `exists`/`adopt`.
        sessions.removeAll()
        for sessionContinuations in continuations.values {
            for continuation in sessionContinuations.values {
                continuation.finish()
            }
        }
        continuations.removeAll()
    }
}
