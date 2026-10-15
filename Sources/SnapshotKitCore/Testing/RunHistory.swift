import Foundation

public enum RunKind: String, Codable, Sendable {
    case run, record, verify, flakeCheck, imported
}

/// A compact record of one test run, kept so flaky tests can be spotted across runs.
public struct RunRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var date: Date
    public var kind: RunKind
    /// "local", an SSH host, or the file name of an imported result bundle.
    public var host: String
    public var commit: String?
    public var branch: String?
    /// Whether the working tree had uncommitted changes (results are then less comparable).
    public var dirty: Bool
    public var passed: Int
    public var failed: Int
    public var skipped: Int
    /// `Bundle/Suite/test()` → outcome per repetition.
    public var outcomes: [String: [TestOutcome]]
    public var resultBundle: String?

    public init(id: UUID = UUID(), date: Date = Date(), kind: RunKind, host: String, commit: String?, branch: String?,
                dirty: Bool, summary: TestRunSummary?, passed: Int, failed: Int, skipped: Int, resultBundle: String?) {
        self.id = id
        self.date = date
        self.kind = kind
        self.host = host
        self.commit = commit
        self.branch = branch
        self.dirty = dirty
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.resultBundle = resultBundle
        var outcomes: [String: [TestOutcome]] = [:]
        for suite in summary?.suites ?? [] {
            for test in suite.tests { outcomes[suite.identifier + "/" + test.name] = test.repetitions }
        }
        self.outcomes = outcomes
    }
}

public struct FlakySignal: Hashable, Sendable, Identifiable {
    public var test: String
    public var passes: Int
    public var failures: Int
    /// Hosts where it was seen failing, e.g. ["local", "ci-mac-1"].
    public var failingHosts: [String]
    public var id: String { test }

    public init(test: String, passes: Int, failures: Int, failingHosts: [String]) {
        self.test = test
        self.passes = passes
        self.failures = failures
        self.failingHosts = failingHosts
    }
}

/// Per-project run history persisted as JSON under the SnapshotKit home directory.
public final class RunHistory: @unchecked Sendable {
    public static let maxRecords = 100
    public let url: URL
    private let lock = NSLock()

    public init(repository: URL, home: URL = SnapshotKitPaths.home) {
        let key = repository.standardizedFileURL.path
        let name = key.split(separator: "/").suffix(2).joined(separator: "-") + "-" + String(UInt(bitPattern: key.stableHash), radix: 36)
        url = home.appendingPathComponent("history/\(name).json")
    }

    public func load() -> [RunRecord] {
        lock.withLock { read() }
    }

    public func append(_ record: RunRecord) {
        lock.withLock {
            var records = read()
            records.append(record)
            if records.count > Self.maxRecords { records.removeFirst(records.count - Self.maxRecords) }
            write(records)
        }
    }

    public func clear() {
        lock.withLock { write([]) }
    }

    /// Tests that both passed and failed for the same commit with a clean tree:
    /// the code did not change, so the outcome did not depend on it.
    public static func flakySignals(_ records: [RunRecord]) -> [FlakySignal] {
        var byCommit: [String: [String: (pass: Int, fail: Int, hosts: Set<String>)]] = [:]
        for record in records where !record.dirty && record.kind != .record {
            guard let commit = record.commit else { continue }
            for (test, outcomes) in record.outcomes {
                var entry = byCommit[commit, default: [:]][test] ?? (0, 0, [])
                entry.pass += outcomes.filter { $0 == .passed }.count
                let fails = outcomes.filter { $0 == .failed }.count
                entry.fail += fails
                if fails > 0 { entry.hosts.insert(record.host) }
                byCommit[commit, default: [:]][test] = entry
            }
        }
        var merged: [String: FlakySignal] = [:]
        for tests in byCommit.values {
            for (test, e) in tests where e.pass > 0 && e.fail > 0 {
                var s = merged[test] ?? FlakySignal(test: test, passes: 0, failures: 0, failingHosts: [])
                s.passes += e.pass
                s.failures += e.fail
                s.failingHosts = Array(Set(s.failingHosts).union(e.hosts)).sorted()
                merged[test] = s
            }
        }
        return merged.values.sorted { $0.test < $1.test }
    }

    private func read() -> [RunRecord] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RunRecord].self, from: data)) ?? []
    }

    private func write(_ records: [RunRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(records).write(to: url, options: .atomic)
    }
}

extension RunRecord {
    /// Captures git state for a run in `repository`.
    public static func make(kind: RunKind, host: String, repository: URL, result: TestRunResult) -> RunRecord {
        let git = Git(root: repository)
        let dirty = !(git.tryRun(["status", "--porcelain", "--untracked-files=no"]) ?? "").isEmpty
        return RunRecord(kind: kind, host: host, commit: git.tryRun(["rev-parse", "HEAD"]), branch: git.currentBranch(),
                         dirty: dirty, summary: result.summary, passed: result.passed, failed: result.failed,
                         skipped: result.skipped, resultBundle: result.resultBundle.path)
    }
}

extension String {
    /// FNV-1a; stable across launches, unlike `hashValue`.
    var stableHash: Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(truncatingIfNeeded: hash)
    }
}
