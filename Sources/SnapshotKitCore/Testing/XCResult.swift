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

    /// The simulators of a run on several: a Device node's `nodeIdentifier` is a `deviceId`.
    public struct Device: Decodable, Sendable {
        public var deviceId: String?
        public var deviceName: String?
    }

    public var testNodes: [Node]
    public var devices: [Device]?
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
    /// What the test is shown as: a Swift Testing display name (`@Test("Pay button")`), else the
    /// function's name. Never use it to address the test; `identifier` does.
    public var name: String
    /// Identifier relative to the bundle, e.g. `GreetingViewTests/greeting()`.
    public var identifier: String
    public var outcome: TestOutcome
    public var failureMessages: [String]
    public var duration: Double?
    /// One outcome per repetition when run with `-test-iterations`/retries; otherwise `[outcome]`.
    public var repetitions: [TestOutcome]
    /// The simulator each repetition ran on, in step with `repetitions`, for a run on several;
    /// nil for a run on one (and in files written by older versions).
    public var repetitionDevices: [String]?

    public init(name: String, identifier: String, outcome: TestOutcome, failureMessages: [String], duration: Double? = nil,
                repetitions: [TestOutcome], repetitionDevices: [String]? = nil) {
        self.name = name
        self.identifier = identifier
        self.outcome = outcome
        self.failureMessages = failureMessages
        self.duration = duration
        self.repetitions = repetitions
        self.repetitionDevices = repetitionDevices
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

    /// The suite's type (`path` holds type names, never a Swift Testing display name), or the bundle.
    public var name: String { path.last ?? bundle }
    public var identifier: String { ([bundle] + path).joined(separator: "/") }
    public var id: String { identifier }

    /// What `-only-testing:` takes to run one of the suite's tests, `Bundle/Suite/test()`: also
    /// how the history, the last run and flakiness verdicts name the test.
    public func onlyTestingIdentifier(of test: TestCaseResult) -> String {
        bundle + "/" + test.identifier
    }

    /// What `-only-testing:` takes to run the suite. The tests outside any type (`path` empty) are
    /// named one by one, the failing ones when any failed: the bundle alone would run every test
    /// in it, and those that pass don't need recording.
    public var onlyTestingIdentifiers: [String] {
        path.isEmpty ? testsToRecord.map(onlyTestingIdentifier) : [identifier]
    }

    /// The failing tests, or every test when none failed (a suite named on the command line).
    var testsToRecord: [TestCaseResult] {
        let failing = tests.filter { $0.outcome == .failed }
        return failing.isEmpty ? tests : failing
    }

    /// `suites` with the tests that `newer` has results for replaced by those results.
    public static func merging(_ newer: [SuiteResult], into suites: [SuiteResult]) -> [SuiteResult] {
        var merged = suites
        for suite in newer {
            guard let i = merged.firstIndex(where: { $0.identifier == suite.identifier }) else {
                merged.append(suite)
                continue
            }
            let ran = Set(suite.tests.map(\.identifier))
            merged[i].tests = merged[i].tests.filter { !ran.contains($0.identifier) } + suite.tests
            merged[i].failureFiles += suite.failureFiles.filter { !merged[i].failureFiles.contains($0) }
        }
        return merged
    }

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
        // A Device node is named after the model ("iPhone 18 Pro"); the simulator's own name tells
        // two of one model apart, and is the one the attachments use.
        var deviceNames: [String: String] = [:]
        for device in tests.devices ?? [] {
            if let id = device.deviceId, let name = device.deviceName { deviceNames[id] = name }
        }
        var suites: [String: SuiteResult] = [:]
        var order: [String] = []

        func visit(_ node: XCResultTests.Node, bundle: String?, suitePath: [String]) {
            switch node.nodeType {
            case "Unit test bundle", "UI test bundle":
                for child in node.children ?? [] { visit(child, bundle: node.name, suitePath: []) }
            case "Test Suite":
                for child in node.children ?? [] { visit(child, bundle: bundle, suitePath: suitePath + [typeName(of: node)]) }
            case "Test Case":
                let bundleName = bundle ?? "Tests"
                let key = ([bundleName] + suitePath).joined(separator: "/")
                var messages: [String] = []
                var files: [String] = []
                collectFailures(node, messages: &messages, files: &files)
                let runs = runs(of: node, deviceNames: deviceNames)
                let test = TestCaseResult(
                    name: node.name,
                    identifier: node.nodeIdentifier ?? (suitePath + [node.name]).joined(separator: "/"),
                    outcome: TestOutcome(xcresult: node.result),
                    failureMessages: messages,
                    duration: node.durationInSeconds,
                    repetitions: runs.map(\.outcome),
                    repetitionDevices: runs.contains { $0.device == nil } ? nil : runs.compactMap(\.device)
                )
                if suites[key] == nil {
                    suites[key] = SuiteResult(bundle: bundleName, path: suitePath, tests: [], failureFiles: [])
                    order.append(key)
                }
                // Multiple configurations/devices report the same test more than once;
                // merge their repetitions, and a failure in any of them counts.
                if let index = suites[key]!.tests.firstIndex(where: { $0.identifier == test.identifier }) {
                    var existing = suites[key]!.tests[index]
                    existing.repetitionDevices = existing.repetitionDevices.flatMap { devices in test.repetitionDevices.map { devices + $0 } }
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

    /// The type a Test Suite node stands for: the end of its `nodeIdentifierURL`
    /// (`test://com.apple.xcode/App/AppTests/CardTests`). Its `name` is a Swift Testing suite's
    /// display name (`@Suite("Card views")`), which `-only-testing:` and the sources don't know.
    static func typeName(of suite: XCResultTests.Node) -> String {
        guard let url = suite.nodeIdentifierURL, let path = url.split(separator: "?").first,
              let last = path.split(separator: "/").last.flatMap({ String($0).removingPercentEncoding }), !last.isEmpty
        else { return suite.name }
        return last
    }

    /// One outcome per run of a test case: per repetition, on each device and test plan
    /// configuration. A repetition sits under the test, under a Device or Configuration node when
    /// there are several, and under each Arguments node of a parameterized test; the cases of one
    /// repetition are one run, which failed if any case failed. Each run names its device, when
    /// under a Device node: by `deviceNames` (simulator names by id), else the node's name.
    static func runs(of testCase: XCResultTests.Node, deviceNames: [String: String] = [:]) -> [(outcome: TestOutcome, device: String?)] {
        var order: [String] = []
        var outcomes: [String: [TestOutcome]] = [:]
        var devices: [String: String] = [:]
        var device: String?
        func add(_ key: String, _ node: XCResultTests.Node) {
            if outcomes[key] == nil { order.append(key) }
            outcomes[key, default: []].append(TestOutcome(xcresult: node.result))
            devices[key] = device
        }
        /// Whether `node` holds a run; a device or configuration without repetitions is one.
        func visit(_ node: XCResultTests.Node, context: String) -> Bool {
            var context = context
            let outer = device
            defer { device = outer }
            switch node.nodeType {
            case "Repetition":
                add(context + "#" + (node.nodeIdentifier ?? node.name), node)
                return true
            case "Device", "Test Plan Configuration":
                context += "/" + (node.nodeIdentifier ?? node.name)
                if node.nodeType == "Device" { device = node.nodeIdentifier.flatMap { deviceNames[$0] } ?? node.name }
            case "Failure Message", "Attachment", "Runtime Warning", "Skip Message", "Source Code Reference":
                return false
            default:
                break
            }
            var found = false
            for child in node.children ?? [] { found = visit(child, context: context) || found }
            if !found, node.nodeType == "Device" || node.nodeType == "Test Plan Configuration" {
                add(context, node)
                return true
            }
            return found
        }
        guard visit(testCase, context: "") else { return [(TestOutcome(xcresult: testCase.result), nil)] }
        return order.map { key in
            let cases = outcomes[key]!
            return (cases.contains(.failed) ? .failed : cases.contains(.passed) ? .passed : cases[0], devices[key])
        }
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

    /// Reads a result bundle with the given Xcode's `xcresulttool`. Blocks until it has finished.
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
