import Foundation

/// One file patched for recording, with enough information to undo the patch exactly.
public struct PatchedFile: Codable, Equatable, Sendable {
    /// Path relative to the repository root.
    public var path: String
    public var suite: String
    public var original: String
    public var patched: String
    /// The changed region (plus a little context) before and after patching,
    /// used to undo only our edit when the file changed in the meantime.
    public var originalSnippet: String
    public var patchedSnippet: String

    public init(path: String, suite: String, original: String, patched: String) {
        self.path = path
        self.suite = suite
        self.original = original
        self.patched = patched
        (originalSnippet, patchedSnippet) = Self.snippets(original: original, patched: patched)
    }

    /// The differing middle of two texts, widened to whole lines so it is unlikely to be ambiguous.
    static func snippets(original: String, patched: String) -> (String, String) {
        let a = Array(original), b = Array(patched)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // Widen to line boundaries.
        var start = prefix
        while start > 0, a[start - 1] != "\n" { start -= 1 }
        var endA = a.count - suffix
        while endA < a.count, a[endA] != "\n" { endA += 1 }
        let endB = b.count - (a.count - endA)
        return (String(a[start..<endA]), String(b[start..<endB]))
    }
}

/// On-disk record of an active patch, stored in the repository's git directory
/// so it survives crashes and is never committed.
public struct PatchJournal: Codable, Equatable, Sendable {
    public var version = 1
    public var repository: String
    public var createdAt: Date
    public var processIdentifier: Int32
    public var files: [PatchedFile]
}

public enum RestoreOutcome: Equatable, Sendable {
    /// File content was put back exactly as it was.
    case restored
    /// The file changed during the run; only SnapshotKit's edit was removed.
    case undidPatchKeepingEdits
    /// Already in its original state.
    case alreadyClean
    /// Could not be undone automatically; the original was saved to `backup`.
    case conflict(backup: String)
    case missing
}

public struct RestoreReport: Sendable {
    public var repository: URL
    public var files: [(path: String, outcome: RestoreOutcome)]

    public var conflicts: [(path: String, backup: String)] {
        files.compactMap { if case .conflict(let b) = $0.outcome { return ($0.path, b) } else { return nil } }
    }

    public var summary: String {
        files.map { file in
            switch file.outcome {
            case .restored: "restored \(file.path)"
            case .undidPatchKeepingEdits: "removed record patch from \(file.path) (kept edits made during the run)"
            case .alreadyClean: "\(file.path) already clean"
            case .conflict(let backup): "could NOT restore \(file.path) automatically; original saved at \(backup)"
            case .missing: "\(file.path) no longer exists"
            }
        }.joined(separator: "\n")
    }
}

/// A temporary record-mode patch over a set of suites. Create with `begin`, end with `restore`.
///
/// Guarantees:
/// - refuses to patch files with uncommitted changes;
/// - writes a journal *before* touching any file;
/// - `restore()` is idempotent and also runs from signal handlers and on next launch.
public final class RecordSession: @unchecked Sendable {
    public let repository: URL
    public let journalURL: URL
    public private(set) var journal: PatchJournal
    private let lock = NSLock()
    private var restored = false

    private init(repository: URL, journalURL: URL, journal: PatchJournal) {
        self.repository = repository
        self.journalURL = journalURL
        self.journal = journal
    }

    public struct Target: Sendable {
        public var suite: String
        /// Path relative to the repository.
        public var path: String
        public init(suite: String, path: String) {
            self.suite = suite
            self.path = path
        }
    }

    public static func journalURL(for repository: URL) throws -> URL {
        try Git(root: repository).gitDirectory().appendingPathComponent("snapshotkit/record-patch.json")
    }

    /// Computes every patch first, then journals, then writes files. Nothing is modified on error.
    public static func begin(repository: URL, targets: [Target]) throws -> RecordSession {
        let git = Git(root: repository)
        let journalURL = try journalURL(for: repository)
        if FileManager.default.fileExists(atPath: journalURL.path) {
            // A leftover from a crash: restore it first rather than stacking patches.
            try restoreLeftover(repository: repository)
        }

        let paths = Array(Set(targets.map(\.path))).sorted()
        let dirty = try git.status(paths: paths)
        if !dirty.isEmpty {
            throw RecordPatchError.uncommittedChanges(dirty.map { String($0.dropFirst(3)) })
        }

        var files: [PatchedFile] = []
        for path in paths {
            let url = repository.appendingPathComponent(path)
            let original = try String(contentsOf: url, encoding: .utf8)
            var patched = original
            for target in targets where target.path == path {
                patched = try RecordPatcher.patch(source: patched, suite: target.suite, file: path)
            }
            let suites = targets.filter { $0.path == path }.map(\.suite).joined(separator: ",")
            files.append(PatchedFile(path: path, suite: suites, original: original, patched: patched))
        }

        let journal = PatchJournal(
            repository: repository.path,
            createdAt: Date(),
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            files: files
        )
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(journal, to: journalURL)
        PatchRegistry.shared.register(repository)

        let session = RecordSession(repository: repository, journalURL: journalURL, journal: journal)
        ActiveSessions.shared.add(session)
        do {
            for file in files {
                try file.patched.write(to: repository.appendingPathComponent(file.path), atomically: true, encoding: .utf8)
            }
        } catch {
            _ = session.restore()
            throw error
        }
        return session
    }

    /// Undoes the patch. Safe to call more than once and from any thread.
    @discardableResult
    public func restore() -> RestoreReport {
        lock.lock()
        defer { lock.unlock() }
        if restored { return RestoreReport(repository: repository, files: journal.files.map { ($0.path, .alreadyClean) }) }
        restored = true
        let report = Self.restore(journal: journal, repository: repository, journalURL: journalURL)
        ActiveSessions.shared.remove(self)
        return report
    }

    static func restore(journal: PatchJournal, repository: URL, journalURL: URL) -> RestoreReport {
        var results: [(String, RestoreOutcome)] = []
        for file in journal.files {
            let url = repository.appendingPathComponent(file.path)
            guard let current = try? String(contentsOf: url, encoding: .utf8) else {
                results.append((file.path, .missing))
                continue
            }
            if current == file.original {
                results.append((file.path, .alreadyClean))
            } else if current == file.patched {
                let ok = (try? file.original.write(to: url, atomically: true, encoding: .utf8)) != nil
                results.append((file.path, ok ? .restored : .conflict(backup: backup(file, journalURL: journalURL))))
            } else if !file.patchedSnippet.isEmpty, current.components(separatedBy: file.patchedSnippet).count == 2 {
                let undone = current.replacingOccurrences(of: file.patchedSnippet, with: file.originalSnippet)
                let ok = (try? undone.write(to: url, atomically: true, encoding: .utf8)) != nil
                results.append((file.path, ok ? .undidPatchKeepingEdits : .conflict(backup: backup(file, journalURL: journalURL))))
            } else {
                results.append((file.path, .conflict(backup: backup(file, journalURL: journalURL))))
            }
        }
        try? FileManager.default.removeItem(at: journalURL)
        PatchRegistry.shared.unregister(repository)
        return RestoreReport(repository: repository, files: results)
    }

    private static func backup(_ file: PatchedFile, journalURL: URL) -> String {
        let dir = journalURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = file.path.replacingOccurrences(of: "/", with: "__") + ".orig"
        let url = dir.appendingPathComponent(name)
        try? file.original.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Restores a journal left behind by a crashed or killed process. Returns nil if there is none.
    @discardableResult
    public static func restoreLeftover(repository: URL, force: Bool = false) throws -> RestoreReport? {
        let url = try journalURL(for: repository)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            PatchRegistry.shared.unregister(repository)
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let journal = try decoder.decode(PatchJournal.self, from: data)
        // Never pull the rug from under a re-record still running in another process.
        let pid = journal.processIdentifier
        if !force, pid != getpid(), kill(pid, 0) == 0, isSnapshotKitProcess(pid) {
            throw RecordPatchError.patchAlreadyActive(repository.path)
        }
        return restore(journal: journal, repository: repository, journalURL: url)
    }

    /// Restores leftovers in every repository that registered a patch (used at app/CLI launch).
    public static func restoreAllLeftovers() -> [RestoreReport] {
        PatchRegistry.shared.repositories().compactMap { repo in
            guard FileManager.default.fileExists(atPath: repo.path) else {
                PatchRegistry.shared.unregister(repo)
                return nil
            }
            return try? restoreLeftover(repository: repo)
        }
    }

    /// Process IDs get reused; only treat a live PID as an owner if it is one of ours.
    static func isSnapshotKitProcess(_ pid: Int32) -> Bool {
        guard let name = try? Shell.output(["ps", "-p", String(pid), "-o", "comm="]) else { return false }
        let base = (name as NSString).lastPathComponent.lowercased()
        return base.hasPrefix("snapkit") || base.hasPrefix("snapshotkit")
    }

    private static func write(_ journal: PatchJournal, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: url, options: .atomic)
    }
}

/// Sessions alive in this process, restored by signal handlers and at termination.
final class ActiveSessions: @unchecked Sendable {
    static let shared = ActiveSessions()
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: RecordSession] = [:]

    func add(_ s: RecordSession) { lock.withLock { sessions[ObjectIdentifier(s)] = s } }
    func remove(_ s: RecordSession) { lock.withLock { sessions[ObjectIdentifier(s)] = nil } }
    func all() -> [RecordSession] { lock.withLock { Array(sessions.values) } }
}

/// Repositories with an active journal, persisted so the next launch can find leftovers.
public final class PatchRegistry: @unchecked Sendable {
    public static let shared = PatchRegistry()
    private let lock = NSLock()

    var url: URL { SnapshotKitPaths.home.appendingPathComponent("active-patches.json") }

    public func repositories() -> [URL] {
        lock.withLock { load().map { URL(fileURLWithPath: $0) } }
    }

    func register(_ repo: URL) {
        lock.withLock {
            var set = Set(load())
            set.insert(repo.standardizedFileURL.path)
            save(set.sorted())
        }
    }

    func unregister(_ repo: URL) {
        lock.withLock {
            var set = Set(load())
            set.remove(repo.standardizedFileURL.path)
            save(set.sorted())
        }
    }

    private func load() -> [String] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func save(_ paths: [String]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(paths).write(to: url, options: .atomic)
    }
}

/// Restores active patches when the process is interrupted or terminated.
public enum InterruptGuard {
    /// Only read and written inside `queue.sync`, which serializes every access.
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    private static let queue = DispatchQueue(label: "snapshotkit.signals")

    /// Installs handlers for SIGINT, SIGTERM, SIGHUP and SIGQUIT that stop child processes
    /// (so nothing keeps recording), restore every active record session, and exit with the
    /// conventional status.
    public static func install(onRestore: (@Sendable (RestoreReport) -> Void)? = nil) {
        queue.sync {
            guard sources.isEmpty else { return }
            for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
                source.setEventHandler {
                    ChildProcesses.shared.terminateAll()
                    for session in ActiveSessions.shared.all() {
                        let report = session.restore()
                        onRestore?(report)
                    }
                    exit(128 + sig)
                }
                source.resume()
                sources.append(source)
            }
        }
    }

    /// Stops child processes and restores every active session (for app termination).
    public static func restoreAll() -> [RestoreReport] {
        ChildProcesses.shared.terminateAll()
        return ActiveSessions.shared.all().map { $0.restore() }
    }
}
