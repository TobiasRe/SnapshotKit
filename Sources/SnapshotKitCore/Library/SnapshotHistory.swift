import Foundation

/// One committed version of a snapshot file.
public struct SnapshotVersion: Identifiable, Hashable, Sendable {
    public var commit: String
    public var author: String
    public var date: Date
    public var subject: String
    public var id: String { commit }
    public var shortCommit: String { String(commit.prefix(7)) }

    public init(commit: String, author: String, date: Date, subject: String) {
        self.commit = commit
        self.author = author
        self.date = date
        self.subject = subject
    }
}

extension Git {
    /// Commits that changed `path`, newest first, following renames. Deletions are left out
    /// (there is no image to show for them).
    public func history(of path: String, limit: Int = 50) -> [SnapshotVersion] {
        let separator = "\u{1F}"
        let format = ["%H", "%an", "%at", "%s"].joined(separator: separator)
        guard let output = tryRun(["log", "--follow", "--diff-filter=AMR", "-n", "\(limit)", "--format=\(format)", "--", path]) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: Character(separator), omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, let seconds = TimeInterval(parts[2]) else { return nil }
            return SnapshotVersion(commit: parts[0], author: parts[1], date: Date(timeIntervalSince1970: seconds), subject: parts[3])
        }
    }

    /// The image as it was in `commit`, following a rename if the path changed since.
    public func image(of path: String, at commit: String) -> Data? {
        if let data = show(revision: commit, path: path) { return data }
        // After a rename the old commit knows the file under its old name: walk the file's log
        // (each commit, then the name it had in that commit) to find it.
        guard let log = try? nulSeparated(["log", "-z", "--follow", "--name-only", "--format=%H", "--", path]) else { return nil }
        var current: String?
        for entry in log {
            // A name follows its commit after a newline.
            let name = String(entry.drop { $0 == "\n" })
            if Self.isCommitHash(name) {
                current = name
            } else if current == commit {
                return show(revision: commit, path: name)
            }
        }
        return nil
    }

    /// A full object name: 40 hex digits, or 64 in a SHA-256 repository.
    static func isCommitHash(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
    }
}
