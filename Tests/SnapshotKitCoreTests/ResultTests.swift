import Foundation
import Testing
@testable import SnapshotKitCore

@Suite struct XCResultParserTests {
    @Test func failedRun() throws {
        let summary = try XCResultParser.parse(fixture("xcresult-tests-failed.json"))
        #expect(summary.total == 1)
        #expect(summary.failed == 1)
        let suite = try #require(summary.failingSuites.first)
        #expect(suite.identifier == "SampleUITests/GreetingViewTests")
        #expect(suite.name == "GreetingViewTests")
        #expect(suite.failureFiles == ["/path/to/repo/Tests/SampleUITests/GreetingViewTests.swift"])
        #expect(suite.tests.first?.identifier == "GreetingViewTests/greeting()")
    }

    @Test func passedRun() throws {
        let summary = try XCResultParser.parse(fixture("xcresult-tests-passed.json"))
        #expect(summary.passed == 1)
        #expect(summary.failingSuites.isEmpty)
    }

    @Test func repetitionsAndFlakiness() throws {
        let summary = try XCResultParser.parse(fixture("xcresult-tests-repetitions.json"))
        let test = try #require(summary.suites.first?.tests.first)
        #expect(test.repetitions == [.failed, .failed, .failed])
        let flakes = Flakiness.classify(summary)
        #expect(flakes.first?.verdict == .alwaysFails)
        #expect(flakes.first?.failed == 3)
    }

    @Test func flakyClassification() {
        let suite = SuiteResult(bundle: "B", path: ["S"], tests: [
            TestCaseResult(name: "a()", identifier: "S/a()", outcome: .failed, failureMessages: [], repetitions: [.passed, .failed, .passed]),
            TestCaseResult(name: "b()", identifier: "S/b()", outcome: .passed, failureMessages: [], repetitions: [.passed, .passed]),
        ], failureFiles: [])
        let verdicts = Flakiness.classify(TestRunSummary(suites: [suite])).map(\.verdict)
        #expect(verdicts == [.flaky, .passes])
    }
}

@Suite struct TestOutputParserTests {
    func lines(_ name: String) throws -> [String] {
        String(decoding: try fixture(name), as: UTF8.self).components(separatedBy: "\n")
    }

    @Test func swiftTestingFailure() throws {
        var parser = TestOutputParser()
        var events: [TestEvent] = []
        for line in try lines("xcodebuild-swift-testing-failed.log") { events += parser.consume(line) }
        #expect(parser.failed == 1)
        #expect(parser.passed == 0)
        #expect(parser.failedTests == ["greeting()"])
        #expect(events.contains(.suiteStarted("GreetingViewTests")))
        #expect(parser.phase == .finished)
    }

    @Test func swiftTestingPass() throws {
        var parser = TestOutputParser()
        for line in try lines("xcodebuild-swift-testing-passed.log") { _ = parser.consume(line) }
        #expect(parser.passed == 1)
        #expect(parser.failed == 0)
    }

    @Test func xctestLinesAndBuildErrors() {
        var parser = TestOutputParser()
        _ = parser.consume("Test Suite 'FeatureTests' started at 2026-01-01")
        _ = parser.consume("Test Case '-[FeatureTests.CardTests testCard]' passed (0.120 seconds).")
        _ = parser.consume("Test case 'CardTests.testDark()' failed on 'Clone 1 of Example Phone' (0.2 seconds)")
        let events = parser.consume("/src/Feature/Card.swift:12:5: error: cannot find 'x' in scope")
        #expect(parser.passed == 1)
        #expect(parser.failedTests == ["CardTests.testDark()"])
        #expect(events == [.buildError("Card.swift:12:5: cannot find 'x' in scope")])
        #expect(parser.phase == .testing)
    }
}

@Suite struct FailureAttachmentTests {
    @Test func groupsReferenceFailureAndDifferencePerRepetition() throws {
        let images = try FailureAttachments.parse(manifest: fixture("attachments-manifest.json"), directory: URL(fileURLWithPath: "/att"))
        #expect(images.count == 3)
        for (i, image) in images.enumerated() {
            #expect(image.testIdentifier == "GreetingViewTests/greeting()")
            #expect(image.repetition == i + 1)
            #expect(image.reference != nil && image.failure != nil && image.difference != nil)
        }
    }

    @Test func roleParsing() {
        #expect(FailureAttachments.role(of: "failure_2_ABC.png")! == ("failure", 2))
        #expect(FailureAttachments.role(of: "reference.png")! == ("reference", 0))
        #expect(FailureAttachments.role(of: "Complete Issue Description.txt") == nil)
    }

    @Test func referencePathFromFailureMessage() {
        let message = "Issue recorded: Snapshot does not match reference.\n\n@\u{2212}\n\"file:///repo/Tests/AppTests/__Snapshots__/CardTests/dark.1.png\"\n@+\n\"file:///sim/tmp/CardTests/dark.1.png\""
        #expect(FailureAttachments.referencePaths(in: message, repository: URL(fileURLWithPath: "/repo")) == ["Tests/AppTests/__Snapshots__/CardTests/dark.1.png"])
        #expect(FailureAttachments.referencePaths(in: message, repository: URL(fileURLWithPath: "/elsewhere")) == ["…/AppTests/__Snapshots__/CardTests/dark.1.png"])
    }
}

@Suite struct TestRunnerArgumentTests {
    @Test func buildsCIEquivalentCommand() {
        var config = SnapshotConfig()
        config.workspace = "App.xcworkspace"
        config.testPlan = "Snapshots"
        config.onlyTesting = ["AppSnapshotTests"]
        config.skipTesting = ["AppSnapshotTests/Slow"]
        let args = TestRunner.arguments(config: config, scheme: "App", destination: "platform=iOS Simulator,id=X",
                                        resultBundlePath: "/r.xcresult", onlyTesting: nil, additional: [])
        #expect(args == ["test", "-workspace", "App.xcworkspace", "-scheme", "App", "-testPlan", "Snapshots",
                         "-destination", "platform=iOS Simulator,id=X", "-resultBundlePath", "/r.xcresult",
                         "-only-testing:AppSnapshotTests", "-skip-testing:AppSnapshotTests/Slow",
                         "-collect-test-diagnostics", "never"])
    }

    @Test func onlyTestingOverrideAndIterations() {
        var config = SnapshotConfig()
        config.onlyTesting = ["All"]
        config.extraArguments = ["-collect-test-diagnostics", "on-failure"]
        let args = TestRunner.arguments(config: config, scheme: "S", destination: "d", resultBundlePath: "r",
                                        onlyTesting: ["B/Suite"], additional: Flakiness.arguments(iterations: 4))
        #expect(args.contains("-only-testing:B/Suite"))
        #expect(!args.contains("-only-testing:All"))
        #expect(args.filter { $0 == "-collect-test-diagnostics" }.count == 1)
        #expect(args.suffix(4) == ["-test-iterations", "4", "-test-repetition-relaunch-enabled", "YES"])
    }

    @Test func modulesFromSnapshotPaths() {
        #expect(SnapshotModules.modules(fromSnapshotPaths: [
            "Tests/FeatureSnapshotTests/__Snapshots__/CardTests/a.1.png",
            "Modules/Login/Tests/LoginTests/Views/__Snapshots__/LoginViewTests/b.png",
            "Tests/FeatureSnapshotTests/__Snapshots__/Other/c.png",
        ]) == ["FeatureSnapshotTests", "LoginTests"])
    }
}

@Suite struct RunHistoryTests {
    func record(_ commit: String, _ outcome: TestOutcome, host: String = "local", dirty: Bool = false) -> RunRecord {
        var r = RunRecord(kind: .run, host: host, commit: commit, branch: "b", dirty: dirty, summary: nil,
                          passed: 0, failed: 0, skipped: 0, resultBundle: nil)
        r.outcomes = ["B/S/a()": [outcome]]
        return r
    }

    @Test func flakySameCommitOnly() {
        let records = [record("c1", .passed), record("c1", .failed, host: "ci-mac"), record("c2", .failed), record("c3", .passed, dirty: true), record("c3", .failed)]
        let signals = RunHistory.flakySignals(records)
        #expect(signals.count == 1)
        #expect(signals[0].test == "B/S/a()")
        #expect(signals[0].failingHosts == ["ci-mac"])
    }

    @Test func persistsAndCaps() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-history-\(UUID().uuidString)")
        let history = RunHistory(repository: URL(fileURLWithPath: "/some/repo"), home: home)
        for i in 0..<(RunHistory.maxRecords + 5) { history.append(record("c\(i)", .passed)) }
        let loaded = history.load()
        #expect(loaded.count == RunHistory.maxRecords)
        #expect(loaded.last?.commit == "c\(RunHistory.maxRecords + 4)")
    }
}

func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}
