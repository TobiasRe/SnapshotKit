import Foundation

public enum FlakeVerdict: String, Codable, Sendable {
    /// Failed in every repetition: a real regression or an outdated reference.
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
}

public struct FlakeResult: Hashable, Codable, Sendable, Identifiable {
    public var suite: String
    public var test: String
    public var passed: Int
    public var failed: Int
    public var verdict: FlakeVerdict
    public var id: String { suite + "/" + test }

    public init(suite: String, test: String, passed: Int, failed: Int, verdict: FlakeVerdict) {
        self.suite = suite
        self.test = test
        self.passed = passed
        self.failed = failed
        self.verdict = verdict
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
                let verdict: FlakeVerdict = failed == 0 ? .passes : (passed == 0 ? .alwaysFails : .flaky)
                return FlakeResult(suite: suite.identifier, test: test.name, passed: passed, failed: failed, verdict: verdict)
            }
        }
    }
}
