import CoreServices
import Foundation

/// Watches a repository for changes to snapshot images (anything under a `__Snapshots__` folder),
/// so a re-record from Xcode or the command line shows up without switching windows.
/// Bursts of events (a test run writing many PNGs) are coalesced into one callback.
public final class SnapshotWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "SnapshotKit.SnapshotWatcher")
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void

    /// - Parameters:
    ///   - latency: how long to wait for more events before calling back.
    ///   - onChange: called on a background queue after snapshot files changed.
    public init(repository: URL, latency: TimeInterval = 0.5, onChange: @escaping @Sendable () -> Void) {
        self.latency = latency
        self.onChange = onChange
        start(path: repository.resolvingSymlinksInPath().path)
    }

    deinit { stop() }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Whether an event path concerns a snapshot image.
    public static func isSnapshotPath(_ path: String) -> Bool {
        path.contains("/__Snapshots__/") || path.hasSuffix("/__Snapshots__")
    }

    private func start(path: String) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SnapshotWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if list.prefix(count).contains(where: SnapshotWatcher.isSnapshotPath) { watcher.onChange() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}
