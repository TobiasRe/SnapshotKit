import Foundation

public enum FlakeVerdict: String, Codable, Sendable {
    /// Failed in every repetition: a real regression or an outdated reference. Also a test that
    /// failed every time on some devices and passed every time on the others (see
    /// `FlakeResult.failingDevices`): that is no flakiness either.
    case alwaysFails
    /// Passed in some repetitions and failed in others.
    case flaky
    /// Passed every time (the earlier failure did not reproduce).
    case passes

    public var label: String {
        switch self {
        case .alwaysFails: "Fails every time"
        case .flaky: "Flaky"
        case .passes: "Passes"
        }
    }

    /// The label, naming the devices when a test fails only on some: "Fails on iPhone SE".
    public func label(failingDevices: [String]?) -> String {
        guard let devices = failingDevices, let last = devices.last else { return label }
        return "Fails on " + (devices.count == 1 ? last : devices.dropLast().joined(separator: ", ") + " and " + last)
    }
}

public struct FlakeResult: Hashable, Codable, Sendable, Identifiable {
    public var suite: String
    public var test: String
    public var passed: Int
    public var failed: Int
    public var verdict: FlakeVerdict
    /// The devices a test failed on every time, when it passed every time on the others; nil
    /// unless it ran on several and they disagreed so.
    public var failingDevices: [String]?
    public var id: String { suite + "/" + test }
    public var label: String { verdict.label(failingDevices: failingDevices) }

    public init(suite: String, test: String, passed: Int, failed: Int, verdict: FlakeVerdict, failingDevices: [String]? = nil) {
        self.suite = suite
        self.test = test
        self.passed = passed
        self.failed = failed
        self.verdict = verdict
        self.failingDevices = failingDevices
    }
}

/// Classifies tests from a run made with `-test-iterations N`.
public enum Flakiness {
    /// xcodebuild arguments for a flakiness check: N independent iterations,
    /// each in a fresh process so state does not leak between repetitions.
    public static func arguments(iterations: Int) -> [String] {
        ["-test-iterations", String(max(minimumIterations, iterations)), "-test-repetition-relaunch-enabled", "YES"]
    }

    /// One run tells nothing about flakiness.
    public static let minimumIterations = 2

    public static func classify(_ summary: TestRunSummary) -> [FlakeResult] {
        summary.suites.flatMap { suite in
            suite.tests.map { test in
                let passed = test.passedRepetitions, failed = test.failedRepetitions
                let devices = failingDevices(test)
                let verdict: FlakeVerdict = failed == 0 ? .passes : (passed == 0 || devices != nil ? .alwaysFails : .flaky)
                return FlakeResult(suite: suite.identifier, test: test.name, passed: passed, failed: failed, verdict: verdict,
                                   failingDevices: devices)
            }
        }
    }

    /// The devices `test` failed on every time while passing every time on all the others, in the
    /// order they ran; nil when it ran on one device, or failed on all, or was flaky on any.
    static func failingDevices(_ test: TestCaseResult) -> [String]? {
        guard let devices = test.repetitionDevices, devices.count == test.repetitions.count else { return nil }
        var order: [String] = []
        var outcomes: [String: [TestOutcome]] = [:]
        for (device, outcome) in zip(devices, test.repetitions) {
            if outcomes[device] == nil { order.append(device) }
            outcomes[device, default: []].append(outcome)
        }
        let failing = order.filter { outcomes[$0]!.allSatisfy { $0 == .failed } }
        let passing = order.filter { outcomes[$0]!.allSatisfy { $0 == .passed } }
        guard !failing.isEmpty, !passing.isEmpty, failing.count + passing.count == order.count else { return nil }
        return failing
    }
}
