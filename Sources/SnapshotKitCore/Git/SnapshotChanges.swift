import Foundation

/// How a snapshot differs from the base branch.
public enum SnapshotChangeKind: String, Codable, CaseIterable, Sendable {
    /// Modified, and the modification is committed on this branch.
    case committed
    /// Modified in the working tree (staged or not) relative to HEAD.
    case uncommitted
    /// Not present on the base branch.
    case new
    /// Present on the base branch, missing now.
    case deleted

    public var label: String {
        switch self {
        case .committed: "Committed"
        case .uncommitted: "Uncommitted"
        case .new: "New"
        case .deleted: "Deleted"
        }
    }
}

public struct SnapshotChange: Identifiable, Hashable, Sendable {
    public var path: String
    public var kind: SnapshotChangeKind

    public var id: String { path }
    public var fileName: String { (path as NSString).lastPathComponent }

    /// swift-snapshot-testing stores images in `__Snapshots__/<TestFile>/<test>.<n>.png`,
    /// so the parent directory names the suite's source file.
    public var suite: String {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.isEmpty ? "(root)" : parent
    }

    /// The test name without the snapshot counter and extension.
    public var testName: String {
        var name = (fileName as NSString).deletingPathExtension
        if let dot = name.lastIndex(of: "."), name[name.index(after: dot)...].allSatisfy(\.isNumber) {
            name = String(name[..<dot])
        }
        return name
    }

    public init(path: String, kind: SnapshotChangeKind) {
        self.path = path
        self.kind = kind
    }
}

public struct SnapshotChangeGroup: Identifiable, Hashable, Sendable {
    public var suite: String
    public var changes: [SnapshotChange]
    public var id: String { suite }
}

/// What "the base branch" means when diffing.
public enum DiffBase: String, Codable, CaseIterable, Sendable {
    /// The merge-base with the base branch: only this branch's changes (what a PR shows).
    case mergeBase
    /// The base branch's current tip: also shows changes made there since branching.
    case tip

    public var label: String { self == .mergeBase ? "Merge-base" : "Branch tip" }
}

public struct SnapshotChangeSet: Sendable {
    public var baseBranch: String
    public var baseRef: String
    public var diffBase: DiffBase
    /// The commit images are compared against.
    public var baseCommit: String
    public var changes: [SnapshotChange]

    public init(baseBranch: String, baseRef: String, diffBase: DiffBase, baseCommit: String, changes: [SnapshotChange]) {
        self.baseBranch = baseBranch
        self.baseRef = baseRef
        self.diffBase = diffBase
        self.baseCommit = baseCommit
        self.changes = changes
    }

    public var groups: [SnapshotChangeGroup] { Self.group(changes) }

    public static func group(_ changes: [SnapshotChange]) -> [SnapshotChangeGroup] {
        Dictionary(grouping: changes, by: \.suite)
            .map { SnapshotChangeGroup(suite: $0.key, changes: $0.value.sorted { $0.path < $1.path }) }
            .sorted { $0.suite.localizedStandardCompare($1.suite) == .orderedAscending }
    }

    /// Case-insensitive filter over path, suite and test name, optionally restricted to kinds.
    public static func filter(_ changes: [SnapshotChange], text: String, kinds: Set<SnapshotChangeKind> = Set(SnapshotChangeKind.allCases)) -> [SnapshotChange] {
        let terms = text.lowercased().split(separator: " ").map(String.init)
        return changes.filter { change in
            guard kinds.contains(change.kind) else { return false }
            let haystack = change.path.lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }
}

public enum SnapshotChangeError: Error, LocalizedError {
    case baseBranchNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .baseBranchNotFound(let branch):
            "Base branch '\(branch)' was not found locally or on origin. Fetch it or choose a different base branch."
        }
    }
}

extension Git {
    /// Lists PNGs that differ between the base (merge-base or tip of `baseBranch`) and the working tree.
    public func snapshotChanges(baseBranch: String, against diffBase: DiffBase = .mergeBase) throws -> SnapshotChangeSet {
        guard let baseRef = resolveBaseRef(baseBranch) else { throw SnapshotChangeError.baseBranchNotFound(baseBranch) }
        let base = diffBase == .mergeBase ? try mergeBase(baseRef) : try run(["rev-parse", baseRef])

        // Base → working tree (includes staged and unstaged edits of tracked files).
        let sinceBase = try run(["diff", "--name-status", "--no-renames", base, "--", "*.png"])
        // HEAD → working tree, to tell committed from uncommitted modifications.
        let sinceHead = Set(try run(["diff", "--name-only", "--no-renames", "HEAD", "--", "*.png"])
            .split(separator: "\n").map(String.init))
        let untracked = try run(["ls-files", "--others", "--exclude-standard", "--", "*.png"])
            .split(separator: "\n").map(String.init)

        var changes: [String: SnapshotChange] = [:]
        for line in sinceBase.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let status = parts[0].first else { continue }
            let path = parts[1]
            let kind: SnapshotChangeKind
            switch status {
            case "A": kind = .new
            case "D":
                // Gone from the index but back on disk (untracked): the untracked pass below decides.
                if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) { continue }
                kind = .deleted
            default: kind = sinceHead.contains(path) ? .uncommitted : .committed
            }
            changes[path] = SnapshotChange(path: path, kind: kind)
        }
        // An untracked file the base also has (re-created after this branch deleted it, or brought
        // back by a revert) is new only if the base doesn't have it; otherwise compare the content.
        let baseBlobs = untracked.isEmpty ? [:] : Dictionary(
            try run(["ls-tree", base, "--"] + untracked).split(separator: "\n").compactMap { line -> (String, String)? in
                // "<mode> blob <hash>\t<path>"
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2, let hash = parts[0].split(separator: " ").last else { return nil }
                return (String(parts[1]), String(hash))
            }, uniquingKeysWith: { a, _ in a })
        let current = baseBlobs.isEmpty ? [] : try run(["hash-object", "--"] + Array(baseBlobs.keys)).split(separator: "\n").map(String.init)
        let unchanged = Set(zip(Array(baseBlobs.keys), current).filter { baseBlobs[$0.0] == $0.1 }.map(\.0))
        for path in untracked where !unchanged.contains(path) {
            changes[path] = SnapshotChange(path: path, kind: baseBlobs[path] == nil ? .new : .uncommitted)
        }

        return SnapshotChangeSet(
            baseBranch: baseBranch,
            baseRef: baseRef,
            diffBase: diffBase,
            baseCommit: base,
            changes: changes.values.sorted { $0.path < $1.path }
        )
    }

    /// Image bytes on the base side (nil for new files).
    public func baseImage(for change: SnapshotChange, in set: SnapshotChangeSet) -> Data? {
        change.kind == .new ? nil : show(revision: set.baseCommit, path: change.path)
    }

    /// Image bytes in the working tree (nil for deleted files).
    public func currentImage(for change: SnapshotChange) -> Data? {
        change.kind == .deleted ? nil : try? Data(contentsOf: root.appendingPathComponent(change.path))
    }

    /// Puts snapshots back the way the base has them: a modified one gets the base's image, a new one
    /// is removed, a deleted one comes back. Only the working tree changes (nothing is staged or
    /// committed), so the result shows as uncommitted changes to review and commit.
    public func revertToBase(_ changes: [SnapshotChange], in set: SnapshotChangeSet) throws {
        let restore = changes.filter { $0.kind != .new }.map(\.path)
        if !restore.isEmpty {
            try run(["restore", "--source=\(set.baseCommit)", "--worktree", "--"] + restore)
        }
        for change in changes where change.kind == .new {
            let url = root.appendingPathComponent(change.path)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    /// Uncommitted snapshot edits that look the same as the committed version: re-records that
    /// only picked up rendering noise. Discarding them keeps a merge request free of churn.
    public func invisibleUncommittedChanges(_ changes: [SnapshotChange]) -> [SnapshotChange] {
        changes.filter { change in
            guard change.kind == .uncommitted,
                  let committed = show(revision: "HEAD", path: change.path).flatMap(PixelImage.init(data:)),
                  let current = currentImage(for: change).flatMap(PixelImage.init(data:)) else { return false }
            let kind = DiffDiagnosis(ImageDiff.compare(committed, current)).kind
            return kind == .imperceptible || kind == .identical
        }
    }
}
