import CryptoKit
import Foundation

/// "Viewed" marks for changed snapshots, like the checkbox on a code review.
///
/// A mark stores a fingerprint of the snapshot as it was when marked, so a snapshot that is
/// re-recorded again shows up as unviewed. Kept in `.git/snapshotkit/viewed.json`: per clone,
/// never committed.
public struct ReviewMarks: Sendable {
    public let url: URL
    let repository: URL

    public init(repository: URL) {
        self.repository = repository
        url = repository.appendingPathComponent(".git/snapshotkit/viewed.json")
    }

    /// Path → fingerprint of every marked snapshot.
    public func load() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let marks = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return marks
    }

    public func save(_ marks: [String: String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(marks).write(to: url, options: .atomic)
    }

    /// What the snapshot looks like now: a hash of the file, or "deleted".
    public func fingerprint(of change: SnapshotChange) -> String {
        guard change.kind != .deleted,
              let data = FileManager.default.contents(atPath: repository.appendingPathComponent(change.path).path) else {
            return "deleted"
        }
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// IDs of the changes whose mark still matches the file.
    public func viewed(in changes: [SnapshotChange]) -> Set<String> {
        let marks = load()
        guard !marks.isEmpty else { return [] }
        return Set(changes.filter { marks[$0.path] != nil && marks[$0.path] == fingerprint(of: $0) }.map(\.id))
    }

    /// Marks or unmarks `change`, dropping marks for snapshots that are no longer changed.
    public func set(_ viewed: Bool, for change: SnapshotChange, keepingOnly changes: [SnapshotChange]) {
        set(viewed, for: [change], keepingOnly: changes)
    }

    /// Marks or unmarks several changes in one write.
    public func set(_ viewed: Bool, for marked: [SnapshotChange], keepingOnly changes: [SnapshotChange]) {
        let current = Set(changes.map(\.path))
        var marks = load().filter { current.contains($0.key) }
        for change in marked { marks[change.path] = viewed ? fingerprint(of: change) : nil }
        save(marks)
    }
}
