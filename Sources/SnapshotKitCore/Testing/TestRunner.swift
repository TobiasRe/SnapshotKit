import Foundation

public struct TestRunResult: Sendable {
    public var commandLine: String
    public var exitStatus: Int32
    public var cancelled: Bool
    public var resultBundle: URL
    /// Parsed from the result bundle; nil if the build failed before tests ran.
    public var summary: TestRunSummary?
    public var passed: Int
    public var failed: Int
    public var skipped: Int
    public var buildErrors: [String]
    /// "local" or the remote machine's label.
    public var host: String = "local"

    public init(commandLine: String, exitStatus: Int32, cancelled: Bool, resultBundle: URL, summary: TestRunSummary?,
                passed: Int, failed: Int, skipped: Int, buildErrors: [String], host: String = "local") {
        self.commandLine = commandLine
        self.exitStatus = exitStatus
        self.cancelled = cancelled
        self.resultBundle = resultBundle
        self.summary = summary
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.buildErrors = buildErrors
        self.host = host
    }

    public var succeeded: Bool { exitStatus == 0 && !cancelled }

    /// Why no test ran, when none did: the build failed, or nothing matched what was asked for.
    /// Nil when tests ran, or the run was cancelled. A record run like that recorded nothing.
    public var nothingTested: String? {
        guard !cancelled, passed + failed + skipped == 0 else { return nil }
        return buildErrors.first.map { "the build failed (\($0))" } ?? "no test ran"
    }
    public var failingSuites: [SuiteResult] { summary?.failingSuites ?? [] }
}

/// Runs `xcodebuild test` with a project's CI configuration and streams its output.
public final class TestRunner: @unchecked Sendable { // `process` and `cancelRequested` are guarded by `lock`.
    public let repository: URL
    public let config: SnapshotConfig
    public let environment: TestEnvironment

    private let lock = NSLock()
    private var process: StreamingProcess?
    private var cancelRequested = false
    /// `xcodebuild -list` can take a while (it resolves packages first): a cancel stops it too.
    private let schemeLookup = Shell.Cancellation()

    /// What runs the tests: `xcodebuild` from the PATH, or a stand-in in tests.
    let xcodebuild: String

    public convenience init(repository: URL, config: SnapshotConfig, environment: TestEnvironment) {
        self.init(repository: repository, config: config, environment: environment, xcodebuild: "xcodebuild")
    }

    init(repository: URL, config: SnapshotConfig, environment: TestEnvironment, xcodebuild: String) {
        self.repository = repository
        self.config = config
        self.environment = environment
        self.xcodebuild = xcodebuild
    }

    public var workingDirectory: URL {
        config.workingDirectory.map { repository.appendingPathComponent($0) } ?? repository
    }

    /// The xcodebuild arguments. `onlyTesting` replaces the configured selection when given.
    public func arguments(scheme: String, onlyTesting: [String]?, resultBundle: URL, additional: [String] = []) -> [String] {
        Self.arguments(config: config, scheme: scheme, destination: environment.destination,
                       resultBundlePath: resultBundle.path, onlyTesting: onlyTesting, additional: additional)
    }

    /// Shared with the remote runner, which uses remote paths.
    public static func arguments(
        config: SnapshotConfig, scheme: String, destination: String, resultBundlePath: String,
        onlyTesting: [String]?, additional: [String]
    ) -> [String] {
        var args = ["test"]
        if let workspace = config.workspace { args += ["-workspace", workspace] }
        else if let project = config.project { args += ["-project", project] }
        args += ["-scheme", scheme]
        if let plan = config.testPlan { args += ["-testPlan", plan] }
        args += ["-destination", destination]
        args += ["-resultBundlePath", resultBundlePath]
        for id in onlyTesting ?? config.onlyTesting { args.append("-only-testing:\(id)") }
        for id in config.skipTesting { args.append("-skip-testing:\(id)") }
        args += config.extraArguments
        // A failing test otherwise triggers a simulator sysdiagnose that can take ten minutes.
        if !(config.extraArguments + additional).contains("-collect-test-diagnostics") {
            args += ["-collect-test-diagnostics", "never"]
        }
        args += additional
        return args
    }

    /// The configured scheme, or the only scheme `xcodebuild -list` reports. Throws
    /// `CancellationError` when the run is cancelled meanwhile.
    public func resolveScheme() throws -> String {
        if let scheme = config.scheme { return scheme }
        var args = [xcodebuild, "-list", "-json"]
        if let workspace = config.workspace { args += ["-workspace", workspace] }
        else if let project = config.project { args += ["-project", project] }
        if schemeLookup.isCancelled { throw CancellationError() }
        let result = try Shell.run(args, in: workingDirectory, environment: environment.processEnvironment, cancellation: schemeLookup)
        if schemeLookup.isCancelled { throw CancellationError() }
        guard result.succeeded else { throw CommandError(command: args, result: result) }
        struct Listing: Decodable {
            struct Container: Decodable { var schemes: [String]? }
            var project: Container?
            var workspace: Container?
        }
        let json = result.stdout.drop { $0 != "{" }
        if let listing = try? JSONDecoder().decode(Listing.self, from: Data(json.utf8)) {
            let schemes = listing.workspace?.schemes ?? listing.project?.schemes ?? []
            if schemes.count == 1 { return schemes[0] }
            if let package = schemes.first(where: { $0.hasSuffix("-Package") }) { return package }
        }
        throw ConfigError.missingScheme
    }

    /// Runs kept per repository, each a result bundle with its exported attachments.
    static let keptResults = 10

    /// Where a repository's result bundles and failure images go: its git directory (per worktree,
    /// never committed, not shared with other repositories and not emptied by macOS like the
    /// temporary folder), or the temporary folder outside a repository.
    static func resultsDirectory(for repository: URL) -> URL {
        let base = (try? Git(root: repository).gitDirectory().appendingPathComponent("snapshotkit"))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotKit")
        return base.appendingPathComponent("results", isDirectory: true)
    }

    /// A path for the next run's result bundle, after making room for it: the newest runs stay,
    /// and always those the last run refers to, whose failures the app and `snapkit failures` show.
    public static func newResultBundleURL(for repository: URL) -> URL {
        let dir = resultsDirectory(for: repository)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let last = LastRun.load(repository: repository)
        pruneResults(in: dir, keeping: Set((last?.referencedPaths ?? []).map(runName)))
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8)).xcresult")
    }

    /// A run's files share a name: `<name>.xcresult` and `<name>.attachments` (only the latter for
    /// a remote run, whose bundle stays on the remote machine).
    private static func runName(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    /// Leaves the newest `keptResults - 1` runs (room for the next one) and the runs named in `kept`.
    static func pruneResults(in dir: URL, keeping kept: Set<String>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        func created(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        let runs = Dictionary(grouping: entries.filter { ["xcresult", "attachments"].contains($0.pathExtension) }) { runName($0.path) }
        let newestFirst = runs.sorted { $0.value.map(created).max()! > $1.value.map(created).max()! }
        for (name, files) in newestFirst.dropFirst(keptResults - 1) where !kept.contains(name) {
            for file in files { try? fm.removeItem(at: file) }
        }
    }

    /// Runs the tests. `onLine` receives every output line; `onEvent` receives parsed
    /// events together with the running totals.
    public func run(
        onlyTesting: [String]? = nil,
        additionalArguments: [String] = [],
        onLine: @escaping @Sendable (String) -> Void = { _ in },
        onEvent: @escaping @Sendable (TestEvent, TestOutputParser) -> Void = { _, _ in }
    ) async throws -> TestRunResult {
        let scheme = try await offCooperativePool { try self.resolveScheme() }
        let bundle = Self.newResultBundleURL(for: repository)
        let process = StreamingProcess(
            executable: xcodebuild,
            arguments: arguments(scheme: scheme, onlyTesting: onlyTesting, resultBundle: bundle, additional: additionalArguments),
            directory: workingDirectory,
            environment: environment.processEnvironment
        )
        let alreadyCancelled: Bool = lock.withLock {
            self.process = process
            return cancelRequested
        }
        if alreadyCancelled { throw CancellationError() }

        onLine("$ " + process.commandLine)
        try process.start()

        var parser = TestOutputParser()
        for await line in process.lines {
            onLine(line)
            for event in parser.consume(line) { onEvent(event, parser) }
        }
        let status = await process.waitForExit()
        for event in parser.finish() { onEvent(event, parser) }

        var summary: TestRunSummary?
        if FileManager.default.fileExists(atPath: bundle.path) {
            let developerDir = environment.xcode.developerDir
            summary = try? await offCooperativePool { try XCResultParser.load(resultBundle: bundle, developerDir: developerDir) }
        }
        return TestRunResult(
            commandLine: process.commandLine,
            exitStatus: status,
            cancelled: process.isCancelled,
            resultBundle: bundle,
            summary: summary,
            passed: summary?.passed ?? parser.passed,
            failed: summary?.failed ?? parser.failed,
            skipped: summary?.skipped ?? parser.skipped,
            buildErrors: parser.buildErrors
        )
    }

    /// Stops the run: xcodebuild gets SIGINT (then SIGTERM and SIGKILL if it lingers), as does the
    /// scheme lookup, and a run that hasn't started yet throws `CancellationError`.
    public func cancel() {
        let process: StreamingProcess? = lock.withLock {
            cancelRequested = true
            return self.process
        }
        schemeLookup.cancel()
        process?.cancel()
    }
}
