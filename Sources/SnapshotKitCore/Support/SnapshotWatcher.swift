import CoreServices
import Foundation

/// Watches a repository for changes to snapshot images (anything under a `__Snapshots__` folder),
/// so a re-record from Xcode or the command line shows up without switching windows.
/// Bursts of events (a test run writing many PNGs) are coalesced into one callback.
public final class SnapshotWatcher: @unchecked Sendable { // `stream` is set in init, then only touched on `queue`.
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "SnapshotKit.SnapshotWatcher")

    /// What the stream calls back. The stream owns it (released along with the stream), so a
    /// callback never reaches a watcher that is already gone.
    private final class Callback: Sendable {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    /// - Parameters:
    ///   - latency: how long to wait for more events before calling back.
    ///   - onChange: called on a background queue after snapshot files changed. Don't call `stop()`
    ///     from it.
    public init(repository: URL, latency: TimeInterval = 0.5, onChange: @escaping @Sendable () -> Void) {
        start(path: repository.resolvingSymlinksInPath().path, latency: latency, onChange: onChange)
    }

    deinit { stop() }

    /// Stops watching. Runs on the stream's queue, so it never overlaps a callback.
    public func stop() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Whether an event path concerns a snapshot image.
    public static func isSnapshotPath(_ path: String) -> Bool {
        path.contains("/__Snapshots__/") || path.hasSuffix("/__Snapshots__")
    }

    private func start(path: String, latency: TimeInterval, onChange: @escaping @Sendable () -> Void) {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(Callback(onChange)).toOpaque(), retain: nil,
            release: { info in info.map { Unmanaged<Callback>.fromOpaque($0).release() } }, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if list.prefix(count).contains(where: SnapshotWatcher.isSnapshotPath) { callback.onChange() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            Unmanaged<Callback>.fromOpaque(context.info!).release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}
