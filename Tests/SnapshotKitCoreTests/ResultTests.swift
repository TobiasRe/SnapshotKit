import Foundation
import Testing
@testable import SnapshotKitCore

@Suite(.isolated) struct XCResultParserTests {
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

    /// Xcode 27, two simulators, `-test-iterations 2`: repetitions sit under a Device node, and a
    /// parameterized test's under its Arguments too.
    @Test func repetitionsOnSeveralDevices() throws {
        let summary = try XCResultParser.parse(fixture("xcresult-tests-two-devices.json"))
        let tests = try #require(summary.suites.first?.tests)
        #expect(tests.map(\.name) == ["greeting()", "named(name:)"])
        // Two runs on each device; one failing case fails that run of a parameterized test.
        #expect(tests[0].repetitions == [.failed, .failed, .failed, .failed])
        #expect(tests[1].repetitions == [.failed, .passed, .passed, .passed])
        #expect(tests[0].failureMessages.count == 4)
        // By the simulators' names: both are an iPhone 18 Pro.
        #expect(tests[0].repetitionDevices == ["SnapshotKit Samples", "SnapshotKit Samples", "Second iPhone", "Second iPhone"])
        #expect(Flakiness.classify(summary).map(\.verdict) == [.alwaysFails, .flaky])
        #expect(Flakiness.classify(summary).map(\.failingDevices) == [nil, nil])
    }

    /// A test that fails every time on one device and passes every time on another is no flaky test:
    /// it fails on that device.
    @Test func aTestThatFailsOnOneDeviceOnly() throws {
        func device(_ id: String, _ results: [String]) -> String {
            let reps = results.enumerated().map { #"{"name": "Repetition \#($0 + 1)", "nodeIdentifier": "\#($0 + 1)", "nodeType": "Repetition", "result": "\#($1)"}"# }
            return #"{"name": "Model", "nodeIdentifier": "\#(id)", "nodeType": "Device", "children": [\#(reps.joined(separator: ","))]}"#
        }
        func test(_ name: String, _ devices: [String]) -> String {
            #"{"name": "\#(name)", "nodeType": "Test Case", "nodeIdentifier": "S/\#(name)", "result": "Failed", "children": [\#(devices.joined(separator: ","))]}"#
        }
        let json = #"""
            {"devices": [{"deviceId": "A", "deviceName": "iPhone SE"}, {"deviceId": "B", "deviceName": "iPhone 18 Pro"}],
             "testNodes": [{"name": "AppTests", "nodeType": "Unit test bundle", "children": [{"name": "S", "nodeType": "Test Suite", "children": [
               \#(test("small()", [device("A", ["Failed", "Failed"]), device("B", ["Passed", "Passed"])])),
               \#(test("flaky()", [device("A", ["Failed", "Passed"]), device("B", ["Passed", "Passed"])])),
               \#(test("both()", [device("A", ["Failed", "Failed"]), device("B", ["Failed", "Failed"])]))]}]}]}
            """#
        let results = Flakiness.classify(try XCResultParser.parse(Data(json.utf8)))
        #expect(results.map(\.verdict) == [.alwaysFails, .flaky, .alwaysFails])
        #expect(results.map(\.failingDevices) == [["iPhone SE"], nil, nil])
        #expect(results.map(\.label) == ["Fails on iPhone SE", "Flaky", "Fails every time"])
        #expect(FlakeVerdict.alwaysFails.label(failingDevices: ["A", "B", "C"]) == "Fails on A, B and C")
    }

    @Test func parameterizedTestCasesWithoutRepetitions() throws {
        let summary = try XCResultParser.parse(fixture("xcresult-tests-parameterized.json"))
        let named = try #require(summary.suites.first?.tests.last)
        #expect(named.repetitions == [.failed])
        #expect(named.failureMessages.count == 2)
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

@Suite(.isolated) struct TestOutputParserTests {
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

    /// Xcode 27: a parameterized test reports its cases and ends "with 2 test cases failed"; and a
    /// result line can start with zero-width spaces (left over from the issue printed before it).
    @Test func swiftTestingParameterizedTestsAndInvisiblePrefixes() throws {
        var parser = TestOutputParser()
        var events: [TestEvent] = []
        for line in try lines("xcodebuild-swift-testing-parameterized.log") { events += parser.consume(line) }
        #expect(parser.failedTests == ["greeting()", "named(name:)"])
        #expect(parser.failed == 2)
        #expect(events.filter { if case .testStarted = $0 { true } else { false } } == [.testStarted("greeting()"), .testStarted("named(name:)")])
        #expect(TestOutputParser.withoutInvisiblePrefix("\u{200B}\u{200B}✘ Test greeting() failed") == "✘ Test greeting() failed")
    }

    /// The runner finishes every run, also one whose output never said so; once is enough.
    @Test func finishesOnce() {
        var parser = TestOutputParser()
        #expect(parser.consume("** TEST FAILED **") == [.phase(.finished)])
        #expect(parser.finish().isEmpty)
        var cut = TestOutputParser()
        _ = cut.consume("Testing started")
        #expect(cut.finish() == [.phase(.finished)])
        #expect(cut.phase == .finished)
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

@Suite(.isolated) struct FailureAttachmentTests {
    @Test func groupsReferenceFailureAndDifferencePerRepetition() throws {
        let images = try FailureAttachments.parse(manifest: fixture("attachments-manifest.json"), directory: URL(fileURLWithPath: "/att"))
        #expect(images.count == 3)
        for (i, image) in images.enumerated() {
            #expect(image.testIdentifier == "GreetingViewTests/greeting()")
            #expect(image.repetition == i + 1)
            #expect(image.reference != nil && image.failure != nil && image.difference != nil)
        }
    }

    /// Both simulators of a run attach images for the same test, repetition and assertion.
    @Test func keepsTheImagesOfEachDeviceApart() throws {
        let images = try FailureAttachments.parse(manifest: fixture("attachments-manifest-two-devices.json"), directory: URL(fileURLWithPath: "/att"))
        #expect(images.count == 4)
        #expect(Set(images.map(\.id)).count == 4)
        let first = try #require(images.first { $0.device == "Second iPhone" && $0.repetition == 1 })
        #expect(first.reference?.lastPathComponent == "22DB9B19-4815-4EBC-8DE2-B153876E454B.png")
        #expect(first.failure != nil && first.difference != nil)
    }

    /// Each case of a parameterized test attaches its own `failure_0_…` images.
    @Test func keepsTheImagesOfEachTestCaseApart() throws {
        let images = try FailureAttachments.parse(manifest: fixture("attachments-manifest-parameterized.json"), directory: URL(fileURLWithPath: "/att"))
        let named = images.filter { $0.testIdentifier == "GreetingViewTests/named(name:)" }
        #expect(named.map(\.arguments) == [[#""Ada""#], [#""Bob""#]])
        #expect(named.allSatisfy { $0.reference != nil && $0.failure != nil && $0.difference != nil })
        #expect(Set(images.map(\.id)).count == 3)
    }

    /// Two test targets each have a `CardTests/card()`; only the identifier's URL names the target.
    @Test func keepsTheImagesOfSameNamedTestsInTwoTargetsApart() throws {
        let manifest = """
            [{"testIdentifier": "CardTests/card()", "testIdentifierURL": "test://com.apple.xcode/App/AppTests/CardTests/card()",
              "attachments": [{"exportedFileName": "A.png", "suggestedHumanReadableName": "failure_0_A.png"}]},
             {"testIdentifier": "CardTests/card()", "testIdentifierURL": "test://com.apple.xcode/App/FeatureTests/CardTests/card()",
              "attachments": [{"exportedFileName": "F.png", "suggestedHumanReadableName": "failure_0_F.png"}]},
             {"testIdentifier": "CardTests/row()", "attachments": [{"exportedFileName": "R.png", "suggestedHumanReadableName": "failure_0_R.png"}]}]
            """
        let images = try FailureAttachments.parse(manifest: Data(manifest.utf8), directory: URL(fileURLWithPath: "/att"))
        #expect(images.map(\.bundle) == [nil, "AppTests", "FeatureTests"])
        #expect(Set(images.map(\.id)).count == 3)

        func suite(_ bundle: String, _ test: String) -> (TestCaseResult, SuiteResult) {
            let test = TestCaseResult(name: test, identifier: "CardTests/\(test)", outcome: .failed, failureMessages: [], repetitions: [.failed])
            return (test, SuiteResult(bundle: bundle, path: ["CardTests"], tests: [test], failureFiles: []))
        }
        func failures(of test: (TestCaseResult, SuiteResult)) -> [String?] {
            images.filter { $0.belong(to: test.0, in: test.1) }.map { $0.failure?.lastPathComponent }
        }
        #expect(failures(of: suite("AppTests", "card()")) == ["A.png"])
        #expect(failures(of: suite("FeatureTests", "card()")) == ["F.png"])
        // A manifest that doesn't name the target (older Xcode) still finds its test's images.
        #expect(failures(of: suite("AppTests", "row()")) == ["R.png"])
    }

    @Test func reExportReplacesOnlyTheFilesOfTheLastExport() throws {
        let dir = testTemp("out")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outside = testTemp("outside.png")
        for url in [dir.appendingPathComponent("A.png"), dir.appendingPathComponent("notes.txt"), outside] {
            try Data([1]).write(to: url)
        }
        let manifest = #"[{"testIdentifier": "S/t()", "attachments": [{"exportedFileName": "A.png"}, {"exportedFileName": "../\#(outside.lastPathComponent)"}]}]"#
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json"))

        FailureAttachments.removePreviousExport(in: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["notes.txt"])
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func roleParsing() throws {
        #expect(try #require(FailureAttachments.role(of: "failure_2_ABC.png")) == ("failure", 2))
        #expect(try #require(FailureAttachments.role(of: "reference.png")) == ("reference", 0))
        #expect(FailureAttachments.role(of: "Complete Issue Description.txt") == nil)
    }

    @Test func referencePathFromFailureMessage() {
        let message = "Issue recorded: Snapshot does not match reference.\n\n@\u{2212}\n\"file:///repo/Tests/AppTests/__Snapshots__/CardTests/dark.1.png\"\n@+\n\"file:///sim/tmp/CardTests/dark.1.png\""
        #expect(FailureAttachments.referencePaths(in: message, repository: URL(fileURLWithPath: "/repo")) == ["Tests/AppTests/__Snapshots__/CardTests/dark.1.png"])
        #expect(FailureAttachments.referencePaths(in: message, repository: URL(fileURLWithPath: "/elsewhere")) == ["…/AppTests/__Snapshots__/CardTests/dark.1.png"])
    }

    /// The last run's messages name the folder the repository was in when it ran.
    @Test func referencesMatchAfterTheRepositoryMoved() throws {
        let original = try TempRepo()
        let reference = "Tests/AppTests/__Snapshots__/CardTests/dark.1.png"
        try original.write(reference, png(width: 1, height: 1, rgba: (0, 0, 0, 255)))
        try original.commitAll("init")
        let message = "Snapshot does not match reference.\n\n@\u{2212}\n\"file://\(original.url.path)/\(reference)\"\n@+\n\"file:///sim/tmp/CardTests/dark.1.png\""
        let test = TestCaseResult(name: "dark()", identifier: "CardTests/dark()", outcome: .failed, failureMessages: [message], repetitions: [.failed])
        let summary = TestRunSummary(suites: [SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [test], failureFiles: [])])
        LastRun(result: TestRunResult(commandLine: "", exitStatus: 1, cancelled: false, resultBundle: URL(fileURLWithPath: "/r.xcresult"),
                                      summary: summary, passed: 0, failed: 1, skipped: 0, buildErrors: [])).save(repository: original.url)

        let moved = testTemp("moved")
        try FileManager.default.copyItem(at: original.url, to: moved)
        let messages = try #require(LastRun.load(repository: moved)?.failingSuites.first?.tests.first?.failureMessages)
        #expect(messages.flatMap { FailureAttachments.referencePaths(in: $0, repository: moved) } == [reference])
    }

    @Test func referencePathFromADiffToolCommand() {
        let repo = URL(fileURLWithPath: "/my repo")
        // `.snapshots(diffTool: .snapkit)` with `Self { "snapkit open \"\($0)\" \"\($1)\"" }`
        let quoted = "Snapshot does not match reference.\n\nsnapkit open \"/my repo/Tests/AppTests/__Snapshots__/CardTests/dark 2.1.png\" \"/tmp/CardTests/dark 2.1.png\"\n\nNewly-taken snapshot does not match reference."
        #expect(FailureAttachments.referencePaths(in: quoted, repository: repo) == ["Tests/AppTests/__Snapshots__/CardTests/dark 2.1.png"])
        // `diffTool: "ksdiff"`: the string form leaves the paths bare.
        let bare = "Snapshot does not match reference.\n\nksdiff /my-repo/Tests/AppTests/__Snapshots__/CardTests/dark.1.png /tmp/CardTests/dark.1.png\n"
        #expect(FailureAttachments.referencePaths(in: bare, repository: URL(fileURLWithPath: "/my-repo")) == ["Tests/AppTests/__Snapshots__/CardTests/dark.1.png"])
    }
}

@Suite(.isolated) struct TestRunnerArgumentTests {
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
        // The override replaces CI's selection, and the configured diagnostics setting isn't doubled.
        #expect(args == ["test", "-scheme", "S", "-destination", "d", "-resultBundlePath", "r", "-only-testing:B/Suite",
                         "-collect-test-diagnostics", "on-failure", "-test-iterations", "4", "-test-repetition-relaunch-enabled", "YES"])
    }

    @Test func modulesFromSnapshotPaths() {
        #expect(SnapshotModules.modules(fromSnapshotPaths: [
            "Tests/FeatureSnapshotTests/__Snapshots__/CardTests/a.1.png",
            "Modules/Login/Tests/LoginTests/Views/__Snapshots__/LoginViewTests/b.png",
            "Tests/FeatureSnapshotTests/__Snapshots__/Other/c.png",
        ]) == ["FeatureSnapshotTests", "LoginTests"])
    }
}

@Suite(.isolated) struct ResultStorageTests {
    /// What xcodebuild does with the path it is given.
    func newBundle(in repo: TempRepo) throws -> URL {
        let bundle = TestRunner.newResultBundleURL(for: repo.url)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return bundle
    }

    @Test func runsInOneRepositoryNeverRemoveAnothersResults() throws {
        let a = try TempRepo(), b = try TempRepo()
        let bundleOfA = try newBundle(in: a)
        #expect(bundleOfA.path.hasPrefix(try a.git.gitDirectory().path + "/"))
        for _ in 0...TestRunner.keptResults { _ = try newBundle(in: b) }
        #expect(FileManager.default.fileExists(atPath: bundleOfA.path))
    }

    @Test func keepsTheNewestRunsAndTheLastRunsBundle() throws {
        let repo = try TempRepo()
        let last = try newBundle(in: repo)
        let attachments = last.deletingPathExtension().appendingPathExtension("attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        LastRun(result: TestRunResult(commandLine: "", exitStatus: 1, cancelled: false, resultBundle: last, summary: nil,
                                      passed: 0, failed: 1, skipped: 0, buildErrors: []),
                attachmentsDirectory: attachments).save(repository: repo.url)
        let older = try newBundle(in: repo)
        for _ in 0..<TestRunner.keptResults { _ = try newBundle(in: repo) }

        #expect(FileManager.default.fileExists(atPath: last.path))
        #expect(FileManager.default.fileExists(atPath: attachments.path))
        #expect(!FileManager.default.fileExists(atPath: older.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: last.deletingLastPathComponent().path)
        #expect(kept.filter { $0.hasSuffix(".xcresult") }.count == TestRunner.keptResults + 1)
    }

    /// A re-record's verification ran one of two failing tests, which still fails: the last run
    /// shows its images from the verification, and the other's from the full run. Both stay however
    /// many runs follow.
    @Test func keepsTheImagesOfFailuresAVerificationDidNotRun() throws {
        let repo = try TempRepo()
        let full = try newBundle(in: repo)
        let images = full.deletingPathExtension().appendingPathExtension("attachments")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        LastRun.update(with: LastRunTests.run([LastRunTests.suite("CardTests", .failed), LastRunTests.suite("ListTests", .failed)], bundle: "full"),
                       attachmentsDirectory: images, repository: repo.url)
        let verify = try newBundle(in: repo)
        let verifyImages = verify.deletingPathExtension().appendingPathExtension("attachments")
        try FileManager.default.createDirectory(at: verifyImages, withIntermediateDirectories: true)
        LastRun.update(with: LastRunTests.run([LastRunTests.suite("CardTests", .failed)], bundle: "verify"), partial: true,
                       attachmentsDirectory: verifyImages, repository: repo.url)
        for _ in 0...TestRunner.keptResults { _ = try newBundle(in: repo) }

        #expect(FileManager.default.fileExists(atPath: images.path))
        #expect(FileManager.default.fileExists(atPath: verifyImages.path))
    }

    @Test func theLastRunFindsItsResultsInACopyOfTheRepository() throws {
        let original = try TempRepo()
        let bundle = try newBundle(in: original)
        let attachments = bundle.deletingPathExtension().appendingPathExtension("attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        LastRun(result: TestRunResult(commandLine: "", exitStatus: 1, cancelled: false, resultBundle: bundle, summary: nil,
                                      passed: 0, failed: 1, skipped: 0, buildErrors: []),
                attachmentsDirectory: attachments).save(repository: original.url)

        let copy = testTemp("copy")
        try FileManager.default.copyItem(at: original.url, to: copy)
        let last = try #require(LastRun.load(repository: copy))
        let results = try Git(root: copy).gitDirectory().appendingPathComponent("snapshotkit/results").path
        #expect(last.resultBundle == results + "/" + bundle.lastPathComponent)
        #expect(last.attachmentsDirectory == results + "/" + attachments.lastPathComponent)
    }
}

@Suite(.isolated) struct RunHistoryTests {
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

    @Test func timelineSkipsRecordRunsAndMarksMixedRepetitions() {
        var runs: [RunRecord] = []
        for (i, outcomes) in [[TestOutcome.passed], [.failed], [.passed, .failed, .passed], [.skipped]].enumerated() {
            var r = record("c1", .passed)
            r.date = Date(timeIntervalSince1970: Double(i))
            r.outcomes = ["B/S/a()": outcomes]
            runs.append(r)
        }
        var recording = record("c1", .failed)
        recording.kind = .record
        recording.date = Date(timeIntervalSince1970: 10)
        runs.append(recording)
        runs.append(record("c1", .passed).with { $0.outcomes = ["B/S/other()": [.failed]] })

        let points = RunHistory.timeline(for: "B/S/a()", in: runs.reversed())
        #expect(points.map(\.result) == [.passed, .failed, .mixed])
        #expect(RunHistory.timeline(for: "B/S/a()", in: runs, limit: 2).map(\.result) == [.failed, .mixed])
    }

    /// swift-snapshot-testing fails the run that records a missing reference, and the next one
    /// passes on the same commit: with the new reference untracked, that isn't a clean tree.
    @Test func aNewReferenceMakesTheTreeDirtyButBuildProductsDont() throws {
        let repo = try TempRepo()
        try repo.write("Tests/AppTests/CardTests.swift", "")
        try repo.commitAll("init")
        let result = TestRunResult(commandLine: "", exitStatus: 1, cancelled: false, resultBundle: URL(fileURLWithPath: "/r.xcresult"),
                                   summary: nil, passed: 0, failed: 1, skipped: 0, buildErrors: [])
        try repo.write("build/output.log", "")
        #expect(!RunRecord.make(kind: .run, host: "local", repository: repo.url, result: result).dirty)
        try repo.write("Tests/AppTests/__Snapshots__/CardTests/card.1.png", "png")
        #expect(RunRecord.make(kind: .run, host: "local", repository: repo.url, result: result).dirty)
    }

    @Test func sameResultBundleIsRecordedOnce() {
        let history = RunHistory(repository: URL(fileURLWithPath: "/some/repo"), home: testTemp("history"))
        var r = record("c1", .failed)
        r.resultBundle = "/results/a.xcresult"
        history.append(r)
        history.append(r.with { $0.id = UUID() })
        history.append(record("c1", .passed))
        #expect(history.load().count == 2)
    }

    @Test func persistsAndCaps() throws {
        let home = testTemp("history")
        let history = RunHistory(repository: URL(fileURLWithPath: "/some/repo"), home: home)
        for i in 0..<(RunHistory.maxRecords + 5) { history.append(record("c\(i)", .passed)) }
        let loaded = history.load()
        #expect(loaded.count == RunHistory.maxRecords)
        #expect(loaded.last?.commit == "c\(RunHistory.maxRecords + 4)")
    }

    @Test func skipsUnreadableRecordsAndKeepsACopyOfTheFile() throws {
        let history = RunHistory(repository: URL(fileURLWithPath: "/some/repo"), home: testTemp("history"))
        history.append(record("c1", .passed))
        let original = try Data(contentsOf: history.url)
        var json = try #require(try JSONSerialization.jsonObject(with: original) as? [Any])
        json.append(["kind": "fromTheFuture"])
        try JSONSerialization.data(withJSONObject: json).write(to: history.url)

        #expect(history.load().map(\.commit) == ["c1"])
        history.append(record("c2", .passed))
        #expect(history.load().map(\.commit) == ["c1", "c2"])
        let copy = try Data(contentsOf: history.url.appendingPathExtension("corrupt"))
        #expect(try #require(try JSONSerialization.jsonObject(with: copy) as? [Any]).count == 2)
    }

    @Test func anUnreadableFileIsCopiedAsideNotOverwritten() throws {
        let history = RunHistory(repository: URL(fileURLWithPath: "/some/repo"), home: testTemp("history"))
        try FileManager.default.createDirectory(at: history.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: history.url)

        history.append(record("c1", .passed))
        #expect(history.load().map(\.commit) == ["c1"])
        #expect(try String(contentsOf: history.url.appendingPathExtension("corrupt"), encoding: .utf8) == "not json")
    }
}

extension RunRecord {
    func with(_ change: (inout RunRecord) -> Void) -> RunRecord {
        var copy = self
        change(&copy)
        return copy
    }
}

func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}
