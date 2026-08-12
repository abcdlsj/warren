/// Serializes mutations that cross an await boundary (Git metadata, runtime
/// creation and repository I/O). Actor isolation alone is not enough because
/// a second actor call may enter while the first call awaits its repository.
internal actor BurrowApplicationPersistenceGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let continuation = waiters.first {
            waiters.removeFirst()
            continuation.resume()
        } else {
            held = false
        }
    }
}
