import Foundation

/// A repository plus its resolved configuration with per-project overrides applied.
/// Shared by the app and the CLI so both behave identically.
public struct ProjectContext: Sendable {
    public var repository: URL
    public var resolved: ResolvedConfig
    public var settings: ProjectSettings

    public init(repository: URL, resolved: ResolvedConfig, settings: ProjectSettings = ProjectSettings()) {
        self.repository = repository
        self.resolved = resolved
        self.settings = settings
    }

    /// The configuration actually used: CI → .snapshotkit.yml → per-project settings.
    public var config: SnapshotConfig {
        var config = resolved.config
        if let base = settings.baseBranch, !base.isEmpty {
            config.baseBranch = base
            config.sources[SnapshotConfig.Field.baseBranch.rawValue] = "project setting"
        }
        if let host = settings.remoteHost, !host.isEmpty {
            config.remoteHost = host
            config.sources[SnapshotConfig.Field.remoteHost.rawValue] = "project setting"
        }
        if let module = settings.module, !module.isEmpty {
            config.onlyTesting = [module]
            config.sources[SnapshotConfig.Field.onlyTesting.rawValue] = "module picker"
        }
        return config
    }

    public var baseBranch: String? { config.baseBranch }

    public static func load(repository: URL, settings: ProjectSettings = ProjectSettings()) throws -> ProjectContext {
        let root = Git.repository(containing: repository)?.root ?? repository
        return ProjectContext(repository: root, resolved: try ConfigResolver.resolve(repository: root), settings: settings)
    }

    /// Snapshot test targets found in the repository, for the module picker.
    public func modules() -> [String] {
        SnapshotModules.detect(in: Git(root: repository))
    }
}

/// The most recent run's failing suites, shared between the CLI and the app via the git directory.
public struct LastRun: Codable, Sendable {
    public var date: Date
    public var host: String
    public var resultBundle: String?
    public var failingSuites: [SuiteResult]
    public var passed: Int
    public var failed: Int
    /// Exported failure attachments (folder with manifest.json), if any.
    public var attachmentsDirectory: String?
    /// Every suite of the run, passing ones included, for the Run tab's results after a
    /// relaunch. Missing in files written by older versions.
    public var suites: [SuiteResult]?

    public init(result: TestRunResult, attachmentsDirectory: URL? = nil) {
        date = Date()
        host = result.host
        resultBundle = result.resultBundle.path
        self.attachmentsDirectory = attachmentsDirectory?.path
        failingSuites = result.failingSuites
        suites = result.summary?.suites
        passed = result.passed
        failed = result.failed
    }

    static func url(for repository: URL) throws -> URL {
        try Git(root: repository).gitDirectory().appendingPathComponent("snapshotkit/last-run.json")
    }

    public static func load(repository: URL) -> LastRun? {
        guard let url = try? url(for: repository), let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var last = try? decoder.decode(LastRun.self, from: data) else { return nil }
        // The paths name the folder the repository was in, which it may since have moved or been
        // copied from: what is in its own results folder wins.
        let results = TestRunner.resultsDirectory(for: repository)
        func here(_ path: String?) -> String? {
            guard let path else { return nil }
            let local = results.appendingPathComponent((path as NSString).lastPathComponent).path
            return FileManager.default.fileExists(atPath: local) ? local : path
        }
        last.resultBundle = here(last.resultBundle)
        last.attachmentsDirectory = here(last.attachmentsDirectory)
        return last
    }

    /// Takes in `run` as the repository's last run. A cancelled run changes nothing: it has no results
    /// to speak of. A `partial` run of some tests (a re-record's verification) replaces only those
    /// tests' results; its bundle becomes the last run's when no failure is left outside it.
    public static func update(with run: TestRunResult, partial: Bool = false, attachmentsDirectory: URL? = nil, repository: URL) {
        guard !run.cancelled else { return }
        guard partial, var last = load(repository: repository) else {
            LastRun(result: run, attachmentsDirectory: attachmentsDirectory).save(repository: repository)
            return
        }
        let ran = run.summary?.suites ?? []
        last.date = Date()
        last.failingSuites = SuiteResult.merging(ran, into: last.failingSuites).filter(\.isFailing)
        last.failed = last.failingSuites.reduce(0) { $0 + $1.failedCount }
        if let suites = last.suites.map({ SuiteResult.merging(ran, into: $0) }) {
            last.suites = suites
            last.passed = suites.reduce(0) { $0 + $1.passedCount }
        }
        let ranSuites = Set(ran.map(\.identifier))
        if last.failingSuites.allSatisfy({ ranSuites.contains($0.identifier) }) {
            last.host = run.host
            last.resultBundle = run.resultBundle.path
            last.attachmentsDirectory = attachmentsDirectory?.path
        }
        last.save(repository: repository)
    }

    public func save(repository: URL) {
        guard let url = try? Self.url(for: repository) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}
