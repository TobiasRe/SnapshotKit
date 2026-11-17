import Foundation

/// Collects lines from background threads and hands them to the main actor in batches.
final class LineBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var scheduled = false
    var onFlush: (@MainActor ([String]) -> Void)?

    func add(_ line: String) {
        lock.lock()
        pending.append(line)
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.flushNow()
            }
        }
    }

    @MainActor func flushNow() {
        lock.lock()
        let lines = pending
        pending = []
        scheduled = false
        lock.unlock()
        if !lines.isEmpty { onFlush?(lines) }
    }
}
