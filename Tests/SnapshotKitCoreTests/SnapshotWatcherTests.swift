import Foundation
import Testing
@testable import SnapshotKitCore

@Suite(.isolated) struct SnapshotWatcherTests {
    /// No `__Snapshots__` folder exists before the watcher starts: the stream can still report
    /// changes made just before it started, and those would count as snapshot writes.
    @Test func reportsSnapshotWritesAndIgnoresOtherFiles() async throws {
        let repo = testTemp("watch")
        let tests = repo.appendingPathComponent("Tests/AppTests")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        let counter = Counter()
        let watcher = SnapshotWatcher(repository: repo, latency: 0.05) { counter.increment() }
        defer { watcher.stop() }

        // A source file is not a snapshot.
        try Data("x".utf8).write(to: tests.appendingPathComponent("CardTests.swift"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.value == 0)

        let snapshots = tests.appendingPathComponent("__Snapshots__/CardTests")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data([0x89, 0x50]).write(to: snapshots.appendingPathComponent("card.1.png"))
        for _ in 0..<250 where counter.value == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(counter.value >= 1)
    }

    /// Stopped right after starting: a watcher that kept running would report the write below.
    @Test func staysQuietOnceStoppedAndReleased() async throws {
        let snapshots = testTemp("watch").appendingPathComponent("__Snapshots__")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let counter = Counter()
        var watcher: SnapshotWatcher? = SnapshotWatcher(repository: snapshots.deletingLastPathComponent(), latency: 0.05) { counter.increment() }
        watcher?.stop()
        watcher?.stop()
        watcher = nil
        counter.reset()   // whatever arrived before `stop()` returned
        try Data([1]).write(to: snapshots.appendingPathComponent("a.png"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.value == 0)
    }

    @Test func recognisesSnapshotPaths() {
        #expect(SnapshotWatcher.isSnapshotPath("/r/Tests/A/__Snapshots__/S/t.1.png"))
        #expect(SnapshotWatcher.isSnapshotPath("/r/Tests/A/__Snapshots__"))
        #expect(!SnapshotWatcher.isSnapshotPath("/r/Tests/A/SnapshotsTests.swift"))
        #expect(!SnapshotWatcher.isSnapshotPath("/r/Tests/A/__Snapshots__Old/t.png"))
    }
}

private final class Counter: @unchecked Sendable { // `count` is guarded by `lock`.
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
}
