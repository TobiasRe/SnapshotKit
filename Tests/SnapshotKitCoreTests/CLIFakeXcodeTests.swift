import Foundation
import Testing
@testable import SnapshotKitCore

/// `run`, `record`, `rerecord` and `flaky` from start to end, with an Xcode that is a folder with a
/// version.plist and stand-ins for `xcodebuild` and `xcrun` first on the PATH (the remote tests'
/// `FakeMac`). The stand-in `xcodebuild` records when record mode is on in the test source,
/// reports repetitions for `-test-iterations`, and passes otherwise, unless told to fail.
@Suite(.isolated) struct CLIFakeXcodeTests {
    let snapkit = Snapkit()
    let snapshot = "Tests/AppTests/__Snapshots__/CardTests/card.1.png"

    static let passingTest = #"""
        {"testNodes": [{"name": "App", "nodeType": "Test Plan", "result": "Passed", "children": [
          {"name": "AppTests", "nodeType": "Unit test bundle", "result": "Passed", "children": [
            {"name": "CardTests", "nodeType": "Test Suite", "result": "Passed", "children": [
              {"name": "card()", "nodeType": "Test Case", "nodeIdentifier": "CardTests/card()", "result": "Passed"}]}]}]}]}
        """#

    static let flakyTest = #"""
        {"testNodes": [{"name": "App", "nodeType": "Test Plan", "result": "Failed", "children": [
          {"name": "AppTests", "nodeType": "Unit test bundle", "result": "Failed", "children": [
            {"name": "CardTests", "nodeType": "Test Suite", "result": "Failed", "children": [
              {"name": "card()", "nodeType": "Test Case", "nodeIdentifier": "CardTests/card()", "result": "Failed", "children": [
                {"name": "Repetition 1", "nodeType": "Repetition", "result": "Passed"},
                {"name": "Repetition 2", "nodeType": "Repetition", "result": "Failed"},
                {"name": "Repetition 3", "nodeType": "Repetition", "result": "Passed"}]}]}]}]}]}
        """#

    /// A repository with a Swift Testing suite and its reference, and the environment `snapkit`
    /// runs with: the stand-ins on the PATH and a log of the arguments `xcodebuild` got.
    ///
    /// With `FAKE_INTERRUPT_AT` set to `list` (the configuration names no scheme) or `test`,
    /// `xcodebuild` creates `FAKE_INTERRUPT_MARKER` there and waits for the Ctrl-C, having written
    /// `FAKE_RESULTS` as the results of a test run, if set.
    /// `verifyBuildError`: only the runs after recording (the verification) fail to build.
    func setUp(fail: Bool = false, buildError: Bool = false, verifyBuildError: Bool = false) throws -> (TempRepo, [String: String], log: URL) {
        let xcode = testTemp("Xcode").appendingPathExtension("app")
        try FileManager.default.createDirectory(at: xcode.appendingPathComponent("Contents/Developer"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "99.0", "ProductBuildVersion": "99A1"], format: .xml, options: 0)
            .write(to: xcode.appendingPathComponent("Contents/version.plist"))

        let repo = try TempRepo()
        try repo.write(".snapshotkit.yml", "scheme: App\ndevice: Example Phone\ndeveloperDir: \(xcode.path)\n")
        try repo.write("Tests/AppTests/CardTests.swift", RecordSessionTests.suiteSource)
        try repo.write(snapshot, "the old reference")
        try repo.commitAll("init")

        let mac = try FakeMac(xcodebuild: "")
        try """
            #!/bin/bash
            if [ "$1" = -list ]; then
              [ "$FAKE_INTERRUPT_AT" = list ] && { touch "$FAKE_INTERRUPT_MARKER"; sleep 1; }
              echo '{"project": {"schemes": ["App"]}}'
              exit 0
            fi
            echo "$*" >> "$FAKE_XCODEBUILD_LOG"
            args="$*"
            while [ $# -gt 0 ]; do [ "$1" = -resultBundlePath ] && bundle=$2; shift; done
            mkdir -p "$bundle"
            echo '◇ Test run started.'
            if [ "$FAKE_INTERRUPT_AT" = test ]; then
              [ -n "$FAKE_RESULTS" ] && echo "$FAKE_RESULTS" > "$bundle/tests.json"
              trap 'kill $!; exit 130' INT
              sleep 30 >/dev/null 2>&1 &
              touch "$FAKE_INTERRUPT_MARKER"
              wait
            fi
            \(buildError ? #"echo "$PWD/Tests/AppTests/CardTests.swift:6:9: error: cannot find 'draw' in scope"; echo '** TEST FAILED **'; exit 65"# : "")
            \(verifyBuildError ? #"grep -q 'record: .all' Tests/AppTests/CardTests.swift || { echo "$PWD/Tests/AppTests/CardTests.swift:6:9: error: cannot find 'draw' in scope"; echo '** TEST FAILED **'; exit 65; }"# : "")
            if grep -q 'record: .all' Tests/AppTests/CardTests.swift; then
              printf new > \(snapshot)
              echo '\(FakeMac.oneFailingTest)' > "$bundle/tests.json"
            elif [[ "$args" == *-test-iterations* ]]; then
              echo '\(Self.flakyTest)' > "$bundle/tests.json"
            elif [ -z "\(fail ? "fail" : "")" ]; then
              echo '\(Self.passingTest)' > "$bundle/tests.json"
              echo '✔ Test card() passed after 0.1 seconds.'
              echo '** TEST SUCCEEDED **'
              exit 0
            else
              echo '\(FakeMac.oneFailingTest)' > "$bundle/tests.json"
            fi
            echo '✘ Test card() failed after 0.1 seconds with 1 issue.'
            echo '** TEST FAILED **'
            exit 65

            """.write(to: mac.bin.appendingPathComponent("xcodebuild"), atomically: true, encoding: .utf8)
        let log = testTemp("xcodebuild-arguments")
        return (repo, ["PATH": "\(mac.bin.path):/usr/bin:/bin", "FAKE_XCODEBUILD_LOG": log.path], log)
    }

    func xcodebuild(_ bundle: String, only: String? = nil, extra: String = "") -> String {
        "$ xcodebuild test -scheme App -destination 'platform=iOS Simulator,id=SIM-1' -resultBundlePath \(bundle)"
            + (only.map { " " + Shell.quote("-only-testing:" + $0) } ?? "") + " -collect-test-diagnostics never" + extra + "\n"
    }

    let environmentLine = "snapkit: Xcode 99.0 · Example Phone iOS 99.0\n"
    let failed = "▸ Testing\n✘ Test card() failed after 0.1 seconds with 1 issue.\n** TEST FAILED **\n▸ Finished\n"
    let passed = "▸ Testing\n** TEST SUCCEEDED **\n▸ Finished\n"

    @Test func runReportsTheFailingSuitesAndRemembersTheRun() throws {
        let (repo, env, _) = try setUp(fail: true)
        let result = try snapkit("run", "--repo", repo.url.path, environment: env)
        let last = try #require(LastRun.load(repository: repo.url))
        let bundle = try #require(last.resultBundle)
        #expect(bundle.hasPrefix(try repo.git.gitDirectory().path + "/snapshotkit/results/"))
        #expect(bundle.range(of: #"/\d{4}-\d\d-\d\dT\d\d-\d\d-\d\dZ-[0-9A-F]{8}\.xcresult$"#, options: .regularExpression) != nil)
        #expect(Outcome(result) == Outcome(status: 1, stdout: environmentLine + xcodebuild(bundle) + failed + """

            Result: 0 passed, 1 failed, 0 skipped  [local]
            FAILING SUITE: AppTests/CardTests (1/1 tests)
              ✘ card()
            Result bundle: \(bundle)

            """))
        #expect(last.failingSuites.map(\.identifier) == ["AppTests/CardTests"])
        #expect(snapkit.history(of: repo.url).load().map(\.kind) == [.run])
    }

    @Test func runThatPassesExits0() throws {
        let (repo, env, _) = try setUp()
        let result = try snapkit("run", "--repo", repo.url.path, environment: env)
        let bundle = try #require(LastRun.load(repository: repo.url)?.resultBundle)
        #expect(Outcome(result) == Outcome(status: 0, stdout: environmentLine + xcodebuild(bundle) + passed
                                                + "\nResult: 1 passed, 0 failed, 0 skipped  [local]\nResult bundle: \(bundle)\n"))
    }

    /// `--only` replaces CI's selection; with `--iterations` the run is a flakiness check, which
    /// doesn't replace the last run.
    @Test func runOnlySomeTestsSeveralTimes() throws {
        let (repo, env, log) = try setUp(fail: true)
        try snapkit("run", "--repo", repo.url.path, environment: env)
        let last = try #require(LastRun.load(repository: repo.url)?.resultBundle)
        let result = try snapkit("run", "--repo", repo.url.path, "--only", "AppTests/CardTests/card()", "--iterations", "3", environment: env)
        #expect(result.status == 1)
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").last?.hasSuffix(
            " -only-testing:AppTests/CardTests/card() -collect-test-diagnostics never -test-iterations 3 -test-repetition-relaunch-enabled YES") == true)
        #expect(LastRun.load(repository: repo.url)?.resultBundle == last)
        #expect(snapkit.history(of: repo.url).load().map(\.kind) == [.run, .flakeCheck])
    }

    @Test func recordPatchesRecordsRestoresAndVerifies() throws {
        let (repo, env, _) = try setUp()
        let result = try snapkit("record", "--repo", repo.url.path, "card", environment: env)
        let history = snapkit.history(of: repo.url).load()
        #expect(history.map(\.kind) == [.record, .verify])
        let (recorded, verified) = (try #require(history.first?.resultBundle), try #require(history.last?.resultBundle))
        #expect(Outcome(result) == Outcome(status: 0, stdout: "snapkit: recording AppTests/CardTests/card()\n" + environmentLine + """
            ▸ Finding suite sources
            ▸ Enabling record mode
            snapkit: record mode enabled in Tests/AppTests/CardTests.swift (CardTests)
            ▸ Recording snapshots

            """ + xcodebuild(recorded, only: "AppTests/CardTests/card()") + failed + """
            ▸ Restoring test sources
            snapkit: restored Tests/AppTests/CardTests.swift
            ▸ Verifying new references

            """ + xcodebuild(verified, only: "AppTests/CardTests/card()") + passed + "▸ Done\nRecorded and verified: 1 passed.\n"))
        #expect(try repo.read(snapshot) == "new")
        #expect(try repo.read("Tests/AppTests/CardTests.swift") == RecordSessionTests.suiteSource)
        // The verification is the last run now.
        #expect(LastRun.load(repository: repo.url)?.resultBundle == verified)
    }

    /// A `@Test` function outside any type records and verifies just that test, from the library and
    /// from the last run's failures (whose suite is the target, without a path).
    @Test func recordATestOutsideAType() throws {
        let (repo, env, log) = try setUp()
        let source = "import SnapshotTesting\nimport Testing\n\n@Test func card() {}\n"
        try repo.write("Tests/AppTests/CardTests.swift", source)
        try repo.commitAll("a test outside a type")

        let result = try snapkit("record", "--repo", repo.url.path, "card", environment: env)
        #expect(result.status == 0)
        #expect(result.stdout.hasPrefix("snapkit: recording AppTests/card()\n"))
        #expect(result.stdout.contains("snapkit: record mode enabled in Tests/AppTests/CardTests.swift (tests outside a type)\n"))
        #expect(result.stdout.hasSuffix("Recorded and verified: 1 passed.\n"))
        #expect(try repo.read(snapshot) == "new")
        #expect(try repo.read("Tests/AppTests/CardTests.swift") == source)

        try repo.commitAll("recorded")
        LastRun.update(with: LastRunTests.run([SuiteResult(bundle: "AppTests", path: [], tests: [
            TestCaseResult(name: "card()", identifier: "card()", outcome: .failed, failureMessages: [], repetitions: [.failed]),
        ], failureFiles: [])], bundle: "earlier"), repository: repo.url)
        #expect(try snapkit("rerecord", "--repo", repo.url.path, environment: env).status == 0)
        let runs = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").suffix(2)
        #expect(runs.count == 2 && runs.allSatisfy { $0.hasSuffix(" -only-testing:AppTests/card() -collect-test-diagnostics never") })
        #expect(try repo.read("Tests/AppTests/CardTests.swift") == source)
    }

    @Test func recordWithoutVerifying() throws {
        let (repo, env, _) = try setUp()
        let result = try snapkit("record", "--repo", repo.url.path, "card", "--no-verify", environment: env)
        #expect(result.status == 0)
        #expect(result.stdout.hasSuffix("snapkit: restored Tests/AppTests/CardTests.swift\n▸ Done\nRecorded.\n"))
        #expect(snapkit.history(of: repo.url).load().map(\.kind) == [.record])
        #expect(LastRun.load(repository: repo.url) == nil)
    }

    @Test func aBuildThatFailsRecordsNothing() throws {
        let (repo, env, _) = try setUp(buildError: true)
        let result = try snapkit("record", "--repo", repo.url.path, "card", environment: env)
        #expect(result.status == 1)
        #expect(result.stderr == "error: Nothing was recorded: the build failed (CardTests.swift:6:9: cannot find 'draw' in scope).\n")
        #expect(!result.stdout.contains("Verifying"))
        #expect(try repo.read(snapshot) == "the old reference")
        #expect(try repo.read("Tests/AppTests/CardTests.swift") == RecordSessionTests.suiteSource)
    }

    /// Tests that don't build have no failures to find: not "Nothing to re-record" and exit 0.
    @Test func findingTheFailingSuitesWhenTheBuildFails() throws {
        let (repo, env, _) = try setUp(buildError: true)
        let failed = "error: Could not find the failing suites: the build failed (CardTests.swift:6:9: cannot find 'draw' in scope).\n"
        for command in ["rerecord", "flaky"] {
            let result = try snapkit(command, "--repo", repo.url.path, environment: env)
            #expect(result.status == 1)
            #expect(result.stdout.contains("Build errors:\n  CardTests.swift:6:9: cannot find 'draw' in scope\n"))
            #expect(result.stderr == failed)
        }
        // Neither did the run take the last run's place.
        #expect(LastRun.load(repository: repo.url) == nil)
    }

    @Test func rerecordTheLastRunsFailingSuites() throws {
        let (repo, env, _) = try setUp()
        LastRun.update(with: LastRunTests.run([SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [
            TestCaseResult(name: "card()", identifier: "CardTests/card()", outcome: .failed, failureMessages: [], repetitions: [.failed]),
        ], failureFiles: [])], bundle: "earlier"), repository: repo.url)
        let result = try snapkit("rerecord", "--repo", repo.url.path, environment: env)
        #expect(result.status == 0)
        #expect(result.stdout.hasSuffix("""
            ▸ Done

            Recorded suites: AppTests/CardTests
            Patched and restored: Tests/AppTests/CardTests.swift
            Verified: 1 passed with the new references.

            """))
        #expect(try repo.read(snapshot) == "new")
        #expect(LastRun.load(repository: repo.url)?.failingSuites.isEmpty == true)
    }

    /// A verification that didn't build found out nothing: not "0 still failing".
    @Test func aVerificationThatDoesNotBuildSaysSo() throws {
        let (repo, env, _) = try setUp(verifyBuildError: true)
        LastRun.update(with: LastRunTests.run([SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [
            TestCaseResult(name: "card()", identifier: "CardTests/card()", outcome: .failed, failureMessages: [], repetitions: [.failed]),
        ], failureFiles: [])], bundle: "earlier"), repository: repo.url)
        let result = try snapkit("rerecord", "--repo", repo.url.path, environment: env)
        #expect(result.status == 1)
        #expect(result.stderr == "error: Could not verify: the build failed (CardTests.swift:6:9: cannot find 'draw' in scope).\n")
        #expect(!result.stdout.contains("still failing"))
        #expect(try repo.read(snapshot) == "new")                                       // recorded all the same
        #expect(LastRun.load(repository: repo.url)?.failingSuites.map(\.identifier) == ["AppTests/CardTests"])
    }

    /// The environment that has `xcodebuild` wait for a Ctrl-C at `point` (see `setUp`).
    func interrupting(_ env: [String: String], at point: String, marker: URL, results: String = "") -> [String: String] {
        env.merging(["FAKE_INTERRUPT_AT": point, "FAKE_INTERRUPT_MARKER": marker.path, "FAKE_RESULTS": results]) { $1 }
    }

    let interrupted = "\nInterrupted — cancelling (press Ctrl-C again to force quit)…\n"

    /// It said "The operation couldn’t be completed. (Swift.CancellationError error 1.)".
    @Test func ctrlCWhileTheSchemeIsLookedUpCancels() throws {
        let (repo, env, _) = try setUp()
        try repo.write(".snapshotkit.yml", try repo.read(".snapshotkit.yml").replacingOccurrences(of: "scheme: App\n", with: ""))
        let marker = testTemp("interrupt")
        let result = try snapkit.interrupted("run", "--repo", repo.url.path, at: marker,
                                             environment: interrupting(env, at: "list", marker: marker))
        #expect(Outcome(result) == Outcome(status: 1, stdout: environmentLine + "Cancelled.\n", stderr: interrupted))
        #expect(LastRun.load(repository: repo.url) == nil)
    }

    /// Without a last run, `rerecord` runs the tests to find the failing suites; cancelled, that
    /// run found none, and there is nothing to re-record from it.
    @Test func ctrlCWhileFindingTheFailingSuitesCancels() throws {
        let (repo, env, _) = try setUp()
        let marker = testTemp("interrupt")
        let result = try snapkit.interrupted("rerecord", "--repo", repo.url.path, at: marker,
                                             environment: interrupting(env, at: "test", marker: marker))
        let bundle = try #require(snapkit.history(of: repo.url).load().last?.resultBundle)
        #expect(Outcome(result) == Outcome(status: 1, stdout: "snapkit: no previous run recorded; running tests to find failing suites\n"
            + environmentLine + xcodebuild(bundle) + "▸ Testing\n▸ Finished\nCancelled.\n\nResult: 0 passed, 0 failed, 0 skipped  [local]\n"
            + "Result bundle: \(bundle)\n", stderr: interrupted))
        #expect(LastRun.load(repository: repo.url) == nil)
    }

    /// A cancelled check repeated its tests only partly: it gives no verdicts.
    @Test func ctrlCDuringAFlakinessCheckCancels() throws {
        let (repo, env, _) = try setUp()
        let marker = testTemp("interrupt")
        let result = try snapkit.interrupted("flaky", "--repo", repo.url.path, "--suite", "AppTests/CardTests", "--iterations", "3", at: marker,
                                             environment: interrupting(env, at: "test", marker: marker, results: Self.passingTest))
        #expect(result.status == 1)
        #expect(result.stdout.hasSuffix("▸ Finished\nCancelled.\n"))
        #expect(!result.stdout.contains("Passes"))
        #expect(snapkit.history(of: repo.url).load().map(\.kind) == [.flakeCheck])
    }

    @Test func flakyClassifiesEveryTest() throws {
        let (repo, env, _) = try setUp()
        let result = try snapkit("flaky", "--repo", repo.url.path, "--suite", "AppTests/CardTests", "--iterations", "3", environment: env)
        let bundle = try #require(snapkit.history(of: repo.url).load().last?.resultBundle)
        #expect(Outcome(result) == Outcome(status: 1, stdout: "snapkit: running AppTests/CardTests 3×\n" + environmentLine
            + xcodebuild(bundle, only: "AppTests/CardTests", extra: " -test-iterations 3 -test-repetition-relaunch-enabled YES") + failed
            + "\nFlaky              2✔ 1✘  AppTests/CardTests/card()\n"))
        #expect(snapkit.history(of: repo.url).load().map(\.kind) == [.flakeCheck])
    }
}
