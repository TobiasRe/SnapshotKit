import Foundation
import Testing
@testable import SnapshotKitCore

@Suite struct LastRunTests {
    @Test func keepsEverySuiteAndReadsOlderFiles() throws {
        let repo = try TempRepo()
        let passing = SuiteResult(bundle: "AppTests", path: ["ListTests"], tests: [
            TestCaseResult(name: "row()", identifier: "ListTests/row()", outcome: .passed, failureMessages: [], repetitions: [.passed]),
        ], failureFiles: [])
        let failing = SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [
            TestCaseResult(name: "card()", identifier: "CardTests/card()", outcome: .failed, failureMessages: ["x"], repetitions: [.failed]),
        ], failureFiles: [])
        let result = TestRunResult(commandLine: "xcodebuild test", exitStatus: 65, cancelled: false,
                                   resultBundle: URL(fileURLWithPath: "/tmp/r.xcresult"),
                                   summary: TestRunSummary(suites: [passing, failing]),
                                   passed: 1, failed: 1, skipped: 0, buildErrors: [])
        LastRun(result: result).save(repository: repo.url)
        let loaded = try #require(LastRun.load(repository: repo.url))
        #expect(loaded.suites?.map(\.identifier) == ["AppTests/ListTests", "AppTests/CardTests"])
        #expect(loaded.failingSuites.map(\.identifier) == ["AppTests/CardTests"])

        // Files from before `suites` existed still load.
        let url = repo.url.appendingPathComponent(".git/snapshotkit/last-run.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["suites"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(LastRun.load(repository: repo.url)?.suites == nil)
        #expect(LastRun.load(repository: repo.url)?.failed == 1)
    }

    static func suite(_ name: String, _ outcome: TestOutcome) -> SuiteResult {
        SuiteResult(bundle: "AppTests", path: [name], tests: [
            TestCaseResult(name: "a()", identifier: "\(name)/a()", outcome: outcome, failureMessages: [], repetitions: [outcome]),
        ], failureFiles: [])
    }

    static func run(_ suites: [SuiteResult], bundle: String, cancelled: Bool = false) -> TestRunResult {
        let summary = TestRunSummary(suites: suites)
        return TestRunResult(commandLine: "", exitStatus: summary.failed > 0 ? 65 : 0, cancelled: cancelled,
                             resultBundle: URL(fileURLWithPath: "/results/\(bundle).xcresult"), summary: summary,
                             passed: summary.passed, failed: summary.failed, skipped: 0, buildErrors: [])
    }

    /// `snapkit rerecord --suite` verifies only that suite: the other failures are still to fix.
    @Test func aPartialRunReplacesOnlyTheResultsOfTheTestsItRan() throws {
        let repo = try TempRepo()
        LastRun.update(with: Self.run([Self.suite("CardTests", .failed), Self.suite("ListTests", .failed)], bundle: "full"), repository: repo.url)

        LastRun.update(with: Self.run([Self.suite("CardTests", .passed)], bundle: "verify"), partial: true, repository: repo.url)
        var last = try #require(LastRun.load(repository: repo.url))
        #expect(last.failingSuites.map(\.name) == ["ListTests"])
        #expect((last.passed, last.failed) == (1, 1))
        // Its bundle doesn't have the failure that is left.
        #expect(last.resultBundle == "/results/full.xcresult")

        LastRun.update(with: Self.run([Self.suite("ListTests", .passed)], bundle: "verify2"), partial: true, repository: repo.url)
        last = try #require(LastRun.load(repository: repo.url))
        #expect(last.failingSuites.isEmpty)
        #expect(last.resultBundle == "/results/verify2.xcresult")
    }

    @Test func aCancelledRunLeavesTheLastRunAlone() throws {
        let repo = try TempRepo()
        LastRun.update(with: Self.run([Self.suite("CardTests", .failed)], bundle: "full"), repository: repo.url)
        LastRun.update(with: Self.run([], bundle: "cancelled", cancelled: true), repository: repo.url)
        LastRun.update(with: Self.run([], bundle: "cancelled", cancelled: true), partial: true, repository: repo.url)
        #expect(LastRun.load(repository: repo.url)?.failingSuites.map(\.name) == ["CardTests"])
        #expect(LastRun.load(repository: repo.url)?.resultBundle == "/results/full.xcresult")
    }
}
