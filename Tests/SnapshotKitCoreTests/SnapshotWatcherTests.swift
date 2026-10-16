import Foundation
import Testing
@testable import SnapshotKitCore

@Suite struct SnapshotWatcherTests {
    @Test func reportsSnapshotWritesAndIgnoresOtherFiles() async throws {
        let repo = testTemp("watch")
        let snapshots = repo.appendingPathComponent("Tests/AppTests/__Snapshots__/CardTests")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let counter = Counter()
        let watcher = SnapshotWatcher(repository: repo, latency: 0.1) { counter.increment() }
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(500))   // the stream starts asynchronously…
        counter.reset()                                   // …and may still report the folders made above

        // A source file is not a snapshot.
        try Data("x".utf8).write(to: repo.appendingPathComponent("Tests/AppTests/CardTests.swift"))
        try await Task.sleep(for: .milliseconds(600))
        #expect(counter.value == 0)

        try Data([0x89, 0x50]).write(to: snapshots.appendingPathComponent("card.1.png"))
        for _ in 0..<100 where counter.value == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(counter.value >= 1)
    }

    @Test func recognisesSnapshotPaths() {
        #expect(SnapshotWatcher.isSnapshotPath("/r/Tests/A/__Snapshots__/S/t.1.png"))
        #expect(SnapshotWatcher.isSnapshotPath("/r/Tests/A/__Snapshots__"))
        #expect(!SnapshotWatcher.isSnapshotPath("/r/Tests/A/SnapshotsTests.swift"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
}
