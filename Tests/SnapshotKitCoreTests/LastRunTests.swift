import Foundation
import Testing
@testable import SnapshotKitCore

@Suite(.isolated) struct LastRunTests {
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

    /// A run whose tests didn't build found out nothing about them: the failures stay to fix.
    @Test func aRunInWhichNoTestRanLeavesTheLastRunAlone() throws {
        let repo = try TempRepo()
        LastRun.update(with: Self.run([Self.suite("CardTests", .failed)], bundle: "full"), repository: repo.url)
        let buildFailed = TestRunResult(commandLine: "", exitStatus: 65, cancelled: false, resultBundle: URL(fileURLWithPath: "/results/broken.xcresult"),
                                        summary: nil, passed: 0, failed: 0, skipped: 0, buildErrors: ["Card.swift:6:9: cannot find 'draw' in scope"])
        LastRun.update(with: buildFailed, repository: repo.url)
        LastRun.update(with: buildFailed, partial: true, repository: repo.url)
        #expect(LastRun.load(repository: repo.url)?.failingSuites.map(\.name) == ["CardTests"])
        #expect(LastRun.load(repository: repo.url)?.resultBundle == "/results/full.xcresult")
    }

    /// A folder as `xcresulttool export attachments` leaves it, with one image pair for each test.
    static func attachments(_ tests: [String]) throws -> URL {
        let dir = testTemp("run").appendingPathExtension("attachments")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entries = tests.enumerated().map { i, test in
            #"{"testIdentifier": "\#(test)", "attachments": [{"exportedFileName": "f\#(i).png", "suggestedHumanReadableName": "failure_0_\#(i).png"}]}"#
        }
        try Data("[\(entries.joined(separator: ","))]".utf8).write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    static func suite(_ name: String, _ outcomes: [String: TestOutcome]) -> SuiteResult {
        SuiteResult(bundle: "AppTests", path: [name], tests: outcomes.sorted { $0.key < $1.key }.map { test, outcome in
            TestCaseResult(name: test, identifier: "\(name)/\(test)", outcome: outcome, failureMessages: [], repetitions: [outcome])
        }, failureFiles: [])
    }

    /// Re-recording one of a suite's two failing tests: after a relaunch, the other still shows the
    /// full run's images, the re-recorded one its verification's, and the full run's bundle stays.
    @Test func aPartialRunKeepsTheImagesOfTheTestsItDidNotRun() throws {
        let repo = try TempRepo()
        let full = try Self.attachments(["CardTests/a()", "CardTests/b()"])
        LastRun.update(with: Self.run([Self.suite("CardTests", ["a()": .failed, "b()": .failed])], bundle: "full"),
                       attachmentsDirectory: full, repository: repo.url)
        let verify = try Self.attachments(["CardTests/a()"])
        LastRun.update(with: Self.run([Self.suite("CardTests", ["a()": .failed])], bundle: "verify"), partial: true,
                       attachmentsDirectory: verify, repository: repo.url)

        var last = try #require(LastRun.load(repository: repo.url))
        #expect(last.resultBundle == "/results/full.xcresult")
        #expect(last.attachmentsDirectory(for: "AppTests/CardTests/a()")?.path == verify.path)
        #expect(last.attachmentsDirectory(for: "AppTests/CardTests/b()")?.path == full.path)
        #expect(last.failureImages().map { $0.failure?.deletingLastPathComponent().path } == [verify.path, full.path].sorted())

        // A verification of b() that exported nothing: b() has no images, a() still its own.
        LastRun.update(with: Self.run([Self.suite("CardTests", ["b()": .failed])], bundle: "verify2"), partial: true, repository: repo.url)
        last = try #require(LastRun.load(repository: repo.url))
        #expect(last.resultBundle == "/results/full.xcresult")
        #expect(last.failureImages().map(\.testIdentifier) == ["CardTests/a()"])
    }

    /// `FeatureTests/CardTests/a()` passed now, `AppTests/CardTests/a()` failed: only the latter's
    /// images are a failure's, though the run's folder has both.
    @Test func imagesGoWithTheTestOfTheirOwnTarget() throws {
        let repo = try TempRepo()
        let dir = testTemp("run").appendingPathExtension("attachments")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
            [{"testIdentifier": "CardTests/a()", "testIdentifierURL": "test://com.apple.xcode/App/FeatureTests/CardTests/a()",
              "attachments": [{"exportedFileName": "feature.png", "suggestedHumanReadableName": "failure_0_F.png"}]},
             {"testIdentifier": "CardTests/a()", "testIdentifierURL": "test://com.apple.xcode/App/AppTests/CardTests/a()",
              "attachments": [{"exportedFileName": "app.png", "suggestedHumanReadableName": "failure_0_A.png"}]}]
            """.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        var feature = Self.suite("CardTests", .passed)
        feature.bundle = "FeatureTests"
        LastRun.update(with: Self.run([Self.suite("CardTests", .failed), feature], bundle: "full"), attachmentsDirectory: dir, repository: repo.url)
        let last = try #require(LastRun.load(repository: repo.url))
        #expect(last.failureImages().map { $0.failure?.lastPathComponent } == ["app.png"])
    }

    /// A partial run that ran every failing test leaves no images of the earlier run behind.
    @Test func aPartialRunOfEveryFailureTakesOverTheImages() throws {
        let repo = try TempRepo()
        LastRun.update(with: Self.run([Self.suite("CardTests", ["a()": .failed, "b()": .passed])], bundle: "full"),
                       attachmentsDirectory: try Self.attachments(["CardTests/a()"]), repository: repo.url)
        let verify = try Self.attachments(["CardTests/a()"])
        LastRun.update(with: Self.run([Self.suite("CardTests", ["a()": .failed])], bundle: "verify"), partial: true,
                       attachmentsDirectory: verify, repository: repo.url)
        let last = try #require(LastRun.load(repository: repo.url))
        #expect(last.resultBundle == "/results/verify.xcresult")
        #expect(last.attachmentsDirectory == verify.path)
        #expect(last.testAttachments == nil)
    }

    /// A last-run.json written before images were kept per test (or one naming no folder at all, as
    /// older CLIs wrote) still loads, with the images next to its bundle.
    @Test func olderFilesFindTheirImages() throws {
        let repo = try TempRepo()
        let images = try Self.attachments(["CardTests/card()"])
        let bundle = images.deletingPathExtension().appendingPathExtension("xcresult").path
        let url = try LastRun.url(for: repo.url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"date": "2026-01-02T03:04:05Z", "host": "local", "resultBundle": "\(bundle)", "passed": 0, "failed": 1,
             "failingSuites": [{"bundle": "AppTests", "path": ["CardTests"], "failureFiles": [], "tests": [
               {"name": "card()", "identifier": "CardTests/card()", "outcome": "failed", "failureMessages": [], "repetitions": ["failed"]}]}]}
            """.utf8).write(to: url)
        let last = try #require(LastRun.load(repository: repo.url))
        #expect(last.testAttachments == nil)
        #expect(last.failureImages().map(\.testIdentifier) == ["CardTests/card()"])
    }
}
