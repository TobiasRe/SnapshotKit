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

    public var succeeded: Bool { exitStatus == 0 && !cancelled }
    public var failingSuites: [SuiteResult] { summary?.failingSuites ?? [] }
}

/// Runs `xcodebuild test` with a project's CI configuration and streams its output.
public final class TestRunner: @unchecked Sendable {
    public let repository: URL
    public let config: SnapshotConfig
    public let environment: TestEnvironment

    private let lock = NSLock()
    private var process: StreamingProcess?
    private var cancelRequested = false

    public init(repository: URL, config: SnapshotConfig, environment: TestEnvironment) {
        self.repository = repository
        self.config = config
        self.environment = environment
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

    /// The configured scheme, or the only scheme `xcodebuild -list` reports.
    public func resolveScheme() throws -> String {
        if let scheme = config.scheme { return scheme }
        var args = ["xcodebuild", "-list", "-json"]
        if let workspace = config.workspace { args += ["-workspace", workspace] }
        else if let project = config.project { args += ["-project", project] }
        let result = try Shell.run(args, in: workingDirectory, environment: environment.processEnvironment)
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

    public static func newResultBundleURL() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotKit/results", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8)).xcresult")
    }

    /// Runs the tests. `onLine` receives every output line; `onEvent` receives parsed
    /// events together with the running totals.
    public func run(
        onlyTesting: [String]? = nil,
        additionalArguments: [String] = [],
        onLine: @escaping @Sendable (String) -> Void = { _ in },
        onEvent: @escaping @Sendable (TestEvent, TestOutputParser) -> Void = { _, _ in }
    ) async throws -> TestRunResult {
        let scheme = try resolveScheme()
        let bundle = Self.newResultBundleURL()
        let process = StreamingProcess(
            executable: "xcodebuild",
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
        onEvent(.phase(.finished), parser)

        var summary: TestRunSummary?
        if FileManager.default.fileExists(atPath: bundle.path) {
            summary = try? XCResultParser.load(resultBundle: bundle, developerDir: environment.xcode.developerDir)
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

    public func cancel() {
        let process: StreamingProcess? = lock.withLock {
            cancelRequested = true
            return self.process
        }
        process?.cancel()
    }
}
