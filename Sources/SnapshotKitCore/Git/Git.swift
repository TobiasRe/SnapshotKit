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

    /// One `git status --porcelain` entry.
    public struct StatusEntry: Equatable, Sendable {
        /// The two status columns, e.g. `" M"`, `"A "` or `"??"`.
        public var code: String
        public var path: String
    }

    /// Status entries for the given paths or pathspecs (empty when clean).
    public func status(paths: [String]) throws -> [StatusEntry] {
        guard !paths.isEmpty else { return [] }
        var entries = try nulSeparated(["status", "--porcelain", "-z", "--untracked-files=all", "--"] + paths)[...]
        var result: [StatusEntry] = []
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let code = String(entry.prefix(2))
            result.append(StatusEntry(code: code, path: String(entry.dropFirst(3))))
            // A rename or copy is followed by the path it came from.
            if code.contains("R") || code.contains("C") { _ = entries.popFirst() }
        }
        return result
    }

    /// File contents at a revision, or nil if the path did not exist there.
    public func show(revision: String, path: String) -> Data? {
        try? Shell.data(["git", "show", "\(revision):\(path)"], in: root)
    }

    /// Paths of tracked files matching a pathspec.
    public func lsFiles(_ pathspecs: [String]) -> [String] {
        (try? nulSeparated(["ls-files", "-z", "--"] + pathspecs)) ?? []
    }

    /// The output of a command run with `-z`, split at the NULs. Without `-z`, git quotes paths
    /// with non-ASCII or unusual characters (`"gr\303\266\303\237e.png"`); with it, every path
    /// comes back as it is.
    func nulSeparated(_ args: [String]) throws -> [String] {
        let command = ["git"] + args
        let result = try Shell.run(command, in: root)
        guard result.succeeded else { throw CommandError(command: command, result: result) }
        return result.stdout.split(separator: "\0").map(String.init)
    }
}
