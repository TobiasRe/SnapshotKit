import Foundation

/// Thin wrapper over the `git` command line for one repository.
public struct Git: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Finds the repository containing `url`, or nil if it is not inside a git work tree.
    public static func repository(containing url: URL) -> Git? {
        guard let top = try? Shell.output(["git", "rev-parse", "--show-toplevel"], in: url) else { return nil }
        return Git(root: URL(fileURLWithPath: top))
    }

    @discardableResult
    public func run(_ args: [String]) throws -> String {
        try Shell.output(["git"] + args, in: root)
    }

    public func tryRun(_ args: [String]) -> String? {
        try? run(args)
    }

    /// Absolute path of the git directory (works for worktrees too).
    public func gitDirectory() throws -> URL {
        let path = try run(["rev-parse", "--absolute-git-dir"])
        return URL(fileURLWithPath: path)
    }

    public func currentBranch() -> String? {
        tryRun(["symbolic-ref", "--quiet", "--short", "HEAD"])
    }

    public func refExists(_ ref: String) -> Bool {
        tryRun(["rev-parse", "--verify", "--quiet", ref + "^{commit}"]) != nil
    }

    public func localBranches() -> [String] {
        (tryRun(["for-each-ref", "--format=%(refname:short)", "refs/heads"]) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// The branch `origin/HEAD` points at, e.g. "main".
    public func remoteDefaultBranch() -> String? {
        guard let ref = tryRun(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]) else { return nil }
        return ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref
    }

    /// Prefers the remote-tracking ref so a stale local branch does not hide upstream changes.
    public func resolveBaseRef(_ branch: String) -> String? {
        for candidate in ["origin/\(branch)", branch] where refExists(candidate) {
            return candidate
        }
        return nil
    }

    public func mergeBase(_ a: String, _ b: String = "HEAD") throws -> String {
        try run(["merge-base", a, b])
    }

    /// Porcelain status entries for the given paths (empty when clean).
    public func status(paths: [String]) throws -> [String] {
        guard !paths.isEmpty else { return [] }
        // Not trimmed: the leading status column may be a space.
        let args = ["git", "status", "--porcelain", "--untracked-files=all", "--"] + paths
        let result = try Shell.run(args, in: root)
        guard result.succeeded else { throw CommandError(command: args, result: result) }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    /// File contents at a revision, or nil if the path did not exist there.
    public func show(revision: String, path: String) -> Data? {
        try? Shell.data(["git", "show", "\(revision):\(path)"], in: root)
    }

    /// Paths of tracked files matching a pathspec.
    public func lsFiles(_ pathspecs: [String]) -> [String] {
        (tryRun(["ls-files", "--"] + pathspecs) ?? "").split(separator: "\n").map(String.init)
    }
}
