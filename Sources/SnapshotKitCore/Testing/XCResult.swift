import Foundation

/// The test tree from `xcrun xcresulttool get test-results tests`.
public struct XCResultTests: Decodable, Sendable {
    public struct Node: Decodable, Sendable {
        public var name: String
        public var nodeType: String
        public var nodeIdentifier: String?
        public var nodeIdentifierURL: String?
        public var result: String?
        public var durationInSeconds: Double?
        public var sourceLocation: SourceLocation?
        public var children: [Node]?
    }

    public struct SourceLocation: Decodable, Sendable {
        public var filePath: String
        public var lineNumber: Int?
    }

    public var testNodes: [Node]
}

public enum TestOutcome: String, Codable, Sendable {
    case passed, failed, skipped, expectedFailure, unknown

    init(xcresult: String?) {
        switch xcresult {
        case "Passed": self = .passed
        case "Failed": self = .failed
        case "Skipped": self = .skipped
        case "Expected Failure": self = .expectedFailure
        default: self = .unknown
        }
    }
}

public struct TestCaseResult: Hashable, Codable, Sendable {
    public var name: String
    /// Identifier relative to the bundle, e.g. `GreetingViewTests/greeting()`.
    public var identifier: String
    public var outcome: TestOutcome
    public var failureMessages: [String]
    public var duration: Double?
    /// One outcome per repetition when run with `-test-iterations`/retries; otherwise `[outcome]`.
    public var repetitions: [TestOutcome]

    public init(name: String, identifier: String, outcome: TestOutcome, failureMessages: [String], duration: Double? = nil, repetitions: [TestOutcome]) {
        self.name = name
        self.identifier = identifier
        self.outcome = outcome
        self.failureMessages = failureMessages
        self.duration = duration
        self.repetitions = repetitions
    }

    public var failedRepetitions: Int { repetitions.filter { $0 == .failed }.count }
    public var passedRepetitions: Int { repetitions.filter { $0 == .passed }.count }
}

/// A test suite (type) in a test bundle, identified the way `-only-testing:` expects.
public struct SuiteResult: Hashable, Codable, Sendable, Identifiable {
    /// The test bundle (target) name, e.g. `FeatureSnapshotTests`.
    public var bundle: String
    /// Suite path inside the bundle; nested suites are joined with "/".
    public var path: [String]
    public var tests: [TestCaseResult]
    /// Source files that reported failures in this suite.
    public var failureFiles: [String]

    public init(bundle: String, path: [String], tests: [TestCaseResult], failureFiles: [String]) {
        self.bundle = bundle
        self.path = path
        self.tests = tests
        self.failureFiles = failureFiles
    }

    public var name: String { path.last ?? bundle }
    public var identifier: String { ([bundle] + path).joined(separator: "/") }
    public var id: String { identifier }

    public var failedCount: Int { tests.filter { $0.outcome == .failed }.count }
    public var passedCount: Int { tests.filter { $0.outcome == .passed }.count }
    public var isFailing: Bool { failedCount > 0 }
}

public struct TestRunSummary: Codable, Sendable {
    public var suites: [SuiteResult]

    public init(suites: [SuiteResult]) {
        self.suites = suites
    }

    public var failingSuites: [SuiteResult] { suites.filter(\.isFailing) }
    public var passed: Int { suites.reduce(0) { $0 + $1.passedCount } }
    public var failed: Int { suites.reduce(0) { $0 + $1.failedCount } }
    public var skipped: Int { suites.reduce(0) { $0 + $1.tests.filter { $0.outcome == .skipped }.count } }
    public var total: Int { suites.reduce(0) { $0 + $1.tests.count } }
}

public enum XCResultParser {
    public static func parse(_ data: Data) throws -> TestRunSummary {
        let tests = try JSONDecoder().decode(XCResultTests.self, from: data)
        var suites: [String: SuiteResult] = [:]
        var order: [String] = []

        func visit(_ node: XCResultTests.Node, bundle: String?, suitePath: [String]) {
            switch node.nodeType {
            case "Unit test bundle", "UI test bundle":
                for child in node.children ?? [] { visit(child, bundle: node.name, suitePath: []) }
            case "Test Suite":
                for child in node.children ?? [] { visit(child, bundle: bundle, suitePath: suitePath + [node.name]) }
            case "Test Case":
                let bundleName = bundle ?? "Tests"
                let key = ([bundleName] + suitePath).joined(separator: "/")
                var messages: [String] = []
                var files: [String] = []
                collectFailures(node, messages: &messages, files: &files)
                let outcome = TestOutcome(xcresult: node.result)
                let repetitions = (node.children ?? []).filter { $0.nodeType == "Repetition" }.map { TestOutcome(xcresult: $0.result) }
                let test = TestCaseResult(
                    name: node.name,
                    identifier: node.nodeIdentifier ?? (suitePath + [node.name]).joined(separator: "/"),
                    outcome: outcome,
                    failureMessages: messages,
                    duration: node.durationInSeconds,
                    repetitions: repetitions.isEmpty ? [outcome] : repetitions
                )
                if suites[key] == nil {
                    suites[key] = SuiteResult(bundle: bundleName, path: suitePath, tests: [], failureFiles: [])
                    order.append(key)
                }
                // Multiple configurations/devices report the same test more than once;
                // merge their repetitions, and a failure in any of them counts.
                if let index = suites[key]!.tests.firstIndex(where: { $0.name == test.name }) {
                    var existing = suites[key]!.tests[index]
                    existing.repetitions += test.repetitions
                    existing.failureMessages += test.failureMessages
                    if test.outcome == .failed { existing.outcome = .failed }
                    suites[key]!.tests[index] = existing
                } else {
                    suites[key]!.tests.append(test)
                }
                for file in files where !suites[key]!.failureFiles.contains(file) {
                    suites[key]!.failureFiles.append(file)
                }
            default:
                for child in node.children ?? [] { visit(child, bundle: bundle, suitePath: suitePath) }
            }
        }
        for node in tests.testNodes { visit(node, bundle: nil, suitePath: []) }
        return TestRunSummary(suites: order.compactMap { suites[$0] })
    }

    private static func collectFailures(_ node: XCResultTests.Node, messages: inout [String], files: inout [String]) {
        for child in node.children ?? [] {
            if child.nodeType == "Failure Message" {
                messages.append(child.name)
                if let path = child.sourceLocation?.filePath, !files.contains(path) { files.append(path) }
            }
            collectFailures(child, messages: &messages, files: &files)
        }
    }

    /// Reads a result bundle with the given Xcode's `xcresulttool`.
    public static func load(resultBundle: URL, developerDir: String?) throws -> TestRunSummary {
        let env = developerDir.map { ["DEVELOPER_DIR": $0] }
        let result = try Shell.run(
            ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", resultBundle.path],
            environment: env
        )
        guard result.succeeded else {
            throw CommandError(command: ["xcresulttool", "get", "test-results", "tests"], result: result)
        }
        return try parse(Data(result.stdout.utf8))
    }
}
