import Foundation
import Testing
@testable import SnapshotKitCore

@Suite(.isolated) struct SnapshotWatcherTests {
    /// Whether `condition` holds within a few seconds: a watcher calls back when the system tells it.
    func eventually(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    /// A source file isn't a snapshot: the watcher stays quiet, though a control watching for that
    /// very file saw it written. No `__Snapshots__` folder exists before the watchers start: a
    /// stream can still report changes made just before it started.
    @Test func reportsSnapshotWritesAndIgnoresOtherFiles() async throws {
        let repo = testTemp("watch")
        let tests = repo.appendingPathComponent("Tests/AppTests")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        let counter = Counter(), control = Counter()
        let watcher = SnapshotWatcher(repository: repo, latency: 0.05) { counter.increment() }
        let source = SnapshotWatcher(repository: repo, latency: 0.05, isRelevant: { $0.hasSuffix("/CardTests.swift") }) { control.increment() }
        defer { watcher.stop(); source.stop() }

        try Data("x".utf8).write(to: tests.appendingPathComponent("CardTests.swift"))
        try #require(try await eventually { control.value > 0 })
        watcher.flush()     // what it hasn't delivered yet of that write
        #expect(counter.value == 0)

        let snapshots = tests.appendingPathComponent("__Snapshots__/CardTests")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data([0x89, 0x50]).write(to: snapshots.appendingPathComponent("card.1.png"))
        #expect(try await eventually { counter.value > 0 })
    }

    /// Stopped right after starting: the write a live watcher of the same folder reports isn't
    /// reported by the stopped one.
    @Test func staysQuietOnceStoppedAndReleased() async throws {
        let snapshots = testTemp("watch").appendingPathComponent("__Snapshots__")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let counter = Counter(), control = Counter()
        let live = SnapshotWatcher(repository: snapshots.deletingLastPathComponent(), latency: 0.05) { control.increment() }
        defer { live.stop() }
        var watcher: SnapshotWatcher? = SnapshotWatcher(repository: snapshots.deletingLastPathComponent(), latency: 0.05) { counter.increment() }
        watcher?.stop()
        watcher?.stop()
        watcher = nil
        counter.reset()   // whatever arrived before `stop()` returned
        try Data([1]).write(to: snapshots.appendingPathComponent("a.png"))
        try #require(try await eventually { control.value > 0 })
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
