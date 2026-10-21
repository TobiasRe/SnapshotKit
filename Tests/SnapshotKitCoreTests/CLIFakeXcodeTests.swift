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
    /// A home folder whose Applications hold the stand-in Xcode, for a remote run's preflight
    /// (see `setUpRemote`).
    let home = testTemp("home")
    var xcode: URL { home.appendingPathComponent("Applications/Xcode-99.app") }

    static let passingTest = #"""
        {"testNodes": [{"name": "App", "nodeType": "Test Plan", "result": "Passed", "children": [
          {"name": "AppTests", "nodeType": "Unit test bundle", "result": "Passed", "children": [
            {"name": "CardTests", "nodeType": "Test Suite", "result": "Passed", "children": [
              {"name": "card()", "nodeType": "Test Case", "nodeIdentifier": "CardTests/card()", "result": "Passed"}]}]}]}]}
        """#

    /// The manifest of a failing `card()`'s one image, `F.png`.
    static let failureImage = #"[{"testIdentifier": "CardTests/card()", "attachments": [{"exportedFileName": "F.png", "suggestedHumanReadableName": "failure_0_A.png", "repetitionNumber": 1}]}]"#

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
    /// With `FAKE_INTERRUPT_AT` set to `list` (the configuration names no scheme), `test`, or
    /// `verify` (a run without record mode), `xcodebuild` creates `FAKE_INTERRUPT_MARKER` there and
    /// waits for the Ctrl-C, having written `FAKE_RESULTS` as the results of a test run, if set;
    /// `-list` logs that it was interrupted. `FAKE_SCHEMES` replaces what `-list` reports.
    /// A failing `card()` (`fail`) has a failure image; a run of `NoSuchTests` runs no test.
    /// `verifyBuildError`: only the runs after recording (the verification) fail to build.
    func setUp(fail: Bool = false, buildError: Bool = false, verifyBuildError: Bool = false) throws -> (TempRepo, [String: String], log: URL) {
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
              if [ "$FAKE_INTERRUPT_AT" = list ]; then
                # Only the interrupt ends the wait (the bound only keeps a broken cancel from hanging the tests).
                trap 'echo "-list interrupted" >> "$FAKE_XCODEBUILD_LOG"; exit 130' INT
                touch "$FAKE_INTERRUPT_MARKER"
                for _ in $(seq 600); do sleep 0.1; done
              fi
              if [ -n "${FAKE_SCHEMES+set}" ]; then echo "$FAKE_SCHEMES"; else echo '{"project": {"schemes": ["App"]}}'; fi
              exit 0
            fi
            echo "$*" >> "$FAKE_XCODEBUILD_LOG"
            args="$*"
            while [ $# -gt 0 ]; do [ "$1" = -resultBundlePath ] && bundle=$2; shift; done
            mkdir -p "$bundle"
            echo '◇ Test run started.'
            if [ "$FAKE_INTERRUPT_AT" = test ] || { [ "$FAKE_INTERRUPT_AT" = verify ] && ! grep -q 'record: .all' Tests/AppTests/CardTests.swift; }; then
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
            elif [[ "$args" == *NoSuchTests* ]]; then
              echo '{"testNodes": []}' > "$bundle/tests.json"
              echo '** TEST SUCCEEDED **'
              exit 0
            elif [[ "$args" == *-test-iterations* ]]; then
              echo '\(Self.flakyTest)' > "$bundle/tests.json"
            elif [ -z "\(fail ? "fail" : "")" ]; then
              echo '\(Self.passingTest)' > "$bundle/tests.json"
              echo '✔ Test card() passed after 0.1 seconds.'
              echo '** TEST SUCCEEDED **'
              exit 0
            else
              echo '\(FakeMac.oneFailingTest)' > "$bundle/tests.json"
              mkdir -p "$bundle/attachments" && printf png > "$bundle/attachments/F.png"
              echo '\(Self.failureImage)' > "$bundle/attachments/manifest.json"
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
    /// What `record … card` prints until its record run starts.
    var recordingCard: String {
        "snapkit: recording AppTests/CardTests/card()\n" + environmentLine + """
            ▸ Finding suite sources
            ▸ Enabling record mode
            snapkit: record mode enabled in Tests/AppTests/CardTests.swift (CardTests)
            ▸ Recording snapshots

            """
    }
    let restored = "▸ Restoring test sources\nsnapkit: restored Tests/AppTests/CardTests.swift\n"

    /// What `rerecord` prints until its record run starts, re-recording the last run's failing `CardTests`.
    func rerecordingCard(_ time: String) -> String {
        "snapkit: using failing suites from the last run (local, \(time))\nsnapkit: re-recording AppTests/CardTests\n" + environmentLine + """
            ▸ Finding suite sources
            ▸ Enabling record mode
            snapkit: record mode enabled in Tests/AppTests/CardTests.swift (CardTests)
            ▸ Recording snapshots

            """
    }

    /// A last run (`/results/earlier.xcresult`) in which `card()` failed; the time `rerecord` says it is from.
    func lastRunWithCardFailing(in repo: TempRepo) throws -> String {
        LastRun.update(with: LastRunTests.run([SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [
            TestCaseResult(name: "card()", identifier: "CardTests/card()", outcome: .failed, failureMessages: [], repetitions: [.failed]),
        ], failureFiles: [])], bundle: "earlier"), repository: repo.url)
        return try #require(LastRun.load(repository: repo.url)).date.formatted(date: .omitted, time: .shortened)
    }

    /// What a run whose build fails prints: the compiler names the file by its physical path.
    func buildFailed(in repo: TempRepo) throws -> String {
        let root = try #require(try repo.url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        return "▸ Testing\n\(root)/Tests/AppTests/CardTests.swift:6:9: error: cannot find 'draw' in scope\n** TEST FAILED **\n▸ Finished\n"
    }

    func iterations(_ n: Int) -> String { " -test-iterations \(n) -test-repetition-relaunch-enabled YES" }

    /// Where a run's failure images are exported: next to its bundle.
    func imagesFolder(of bundle: String) -> String { (bundle as NSString).deletingPathExtension + ".attachments" }
    let failed = "▸ Testing\n✘ Test card() failed after 0.1 seconds with 1 issue.\n** TEST FAILED **\n▸ Finished\n"
    let passed = "▸ Testing\n** TEST SUCCEEDED **\n▸ Finished\n"

    /// Every value set, the rarer ones too, with its source; then the Xcode used, with a note that
    /// it isn't the version pinned.
    @Test func configShowsEveryValueAndTheXcodeUsed() throws {
        let (repo, env, _) = try setUp()
        try repo.write(".snapshotkit.yml", try repo.read(".snapshotkit.yml") + """
            xcode: "99.1"
            platform: iOS Simulator
            skipTesting: [AppTests/SlowTests]
            extraArguments: -configuration Debug
            remoteDirectory: ~/work/app

            """)
        #expect(Outcome(try snapkit("config", "--repo", repo.url.path, environment: env)) == Outcome(status: 0, stdout: """
            Repository: \(repo.root)
            CI files:   none
            Override:   .snapshotkit.yml
              xcode          99.1  (.snapshotkit.yml)
              developerDir   \(xcode.path)  (.snapshotkit.yml)
              platform       iOS Simulator  (.snapshotkit.yml)
              device         Example Phone  (.snapshotkit.yml)
              os             —
              scheme         App  (.snapshotkit.yml)
              workspace      —
              project        —
              testPlan       —
              onlyTesting    —
              skipTesting    AppTests/SlowTests  (.snapshotkit.yml)
              extraArgs      -configuration Debug  (.snapshotkit.yml)
              baseBranch     develop  (git (auto-detected))
              workingDir     —
              remoteHost     —
              remoteDir      ~/work/app  (.snapshotkit.yml)
              modules        AppTests
            note: No .gitlab-ci.yml or .github/workflows found; using .snapshotkit.yml only.
            \(environmentLine)Xcode used: \(xcode.path)

            """, stderr: "note: Using Xcode 99.0 at `\(xcode.path)` (`developerDir`, from .snapshotkit.yml), not Xcode 99.1 as pinned by "
                + ".snapshotkit.yml: snapshots may differ from CI’s.\n"))
    }

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
            Failure images: 1 (see `snapkit failures`)

            """))
        #expect(last.failingSuites.map(\.identifier) == ["AppTests/CardTests"])
        #expect(last.failureImages().map(\.failure?.path) == [imagesFolder(of: bundle) + "/F.png"])
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

    /// The verification still fails: exit 1, and the last run is the verification's, with the
    /// image of what still fails (it had none, so `snapkit failures` showed no image).
    @Test func aRecordWhoseVerificationStillFails() throws {
        let (repo, env, _) = try setUp(fail: true)
        let result = try snapkit("record", "--repo", repo.url.path, "card", environment: env)
        let history = snapkit.history(of: repo.url).load()
        #expect(history.map(\.kind) == [.record, .verify])
        let (recorded, verified) = (try #require(history.first?.resultBundle), try #require(history.last?.resultBundle))
        #expect(Outcome(result) == Outcome(status: 1, stdout: recordingCard + xcodebuild(recorded, only: "AppTests/CardTests/card()") + failed
            + restored + "▸ Verifying new references\n" + xcodebuild(verified, only: "AppTests/CardTests/card()") + failed
            + "▸ Done\nRecorded, but verification failed: 1 still failing (flaky?).\n"))
        #expect(try repo.read(snapshot) == "new")
        let last = try #require(LastRun.load(repository: repo.url))
        #expect(last.resultBundle == verified)
        #expect(last.failureImages().map(\.failure?.path) == [imagesFolder(of: verified) + "/F.png"])
    }

    /// `rerecord`'s verification still fails: it says so, suggests `snapkit flaky`, and the last
    /// run's failure has the verification's image.
    @Test func aRerecordWhoseVerificationStillFails() throws {
        let (repo, env, _) = try setUp(fail: true)
        let time = try lastRunWithCardFailing(in: repo)
        let result = try snapkit("rerecord", "--repo", repo.url.path, environment: env)
        let history = snapkit.history(of: repo.url).load()
        let (recorded, verified) = (try #require(history.first?.resultBundle), try #require(history.last?.resultBundle))
        #expect(Outcome(result) == Outcome(status: 1, stdout: rerecordingCard(time) + xcodebuild(recorded, only: "AppTests/CardTests") + failed
            + restored + "▸ Verifying new references\n" + xcodebuild(verified, only: "AppTests/CardTests") + failed + """
            ▸ Done

            Recorded suites: AppTests/CardTests
            Patched and restored: Tests/AppTests/CardTests.swift
            Verification failed: 1 still failing (flaky?). Try `snapkit flaky`.

            """))
        let last = try #require(LastRun.load(repository: repo.url))
        #expect(last.failingSuites.map(\.identifier) == ["AppTests/CardTests"])
        #expect(last.failureImages().map(\.failure?.path) == [imagesFolder(of: verified) + "/F.png"])
    }

    /// `record`'s verification that didn't build found out nothing: not "0 still failing".
    @Test func aRecordWhoseVerificationDoesNotBuild() throws {
        let (repo, env, _) = try setUp(verifyBuildError: true)
        let result = try snapkit("record", "--repo", repo.url.path, "card", environment: env)
        let history = snapkit.history(of: repo.url).load()
        let (recorded, verified) = (try #require(history.first?.resultBundle), try #require(history.last?.resultBundle))
        #expect(Outcome(result) == failure("Recorded, but could not verify: the build failed (CardTests.swift:6:9: cannot find 'draw' in scope).",
            stdout: recordingCard + xcodebuild(recorded, only: "AppTests/CardTests/card()") + failed + restored + "▸ Verifying new references\n"
                + xcodebuild(verified, only: "AppTests/CardTests/card()") + (try buildFailed(in: repo)) + "▸ Done\n"))
        #expect(try repo.read(snapshot) == "new")
        #expect(LastRun.load(repository: repo.url) == nil)
    }

    /// Ctrl-C during `record`'s verification: what was recorded stays, and the verification found
    /// out nothing.
    @Test func ctrlCDuringARecordsVerification() throws {
        let (repo, env, _) = try setUp()
        let marker = testTemp("interrupt")
        let result = try snapkit.interrupted("record", "--repo", repo.url.path, "card", at: marker,
                                             environment: interrupting(env, at: "verify", marker: marker))
        let history = snapkit.history(of: repo.url).load()
        #expect(history.map(\.kind) == [.record, .verify])
        let (recorded, verified) = (try #require(history.first?.resultBundle), try #require(history.last?.resultBundle))
        #expect(Outcome(result) == Outcome(status: 1, stdout: recordingCard + xcodebuild(recorded, only: "AppTests/CardTests/card()") + failed
            + restored + "▸ Verifying new references\n" + xcodebuild(verified, only: "AppTests/CardTests/card()")
            + "▸ Testing\n▸ Finished\n▸ Done\nRecorded; the verification was cancelled.\n", stderr: interrupted))
        #expect(try repo.read(snapshot) == "new")
        #expect(try repo.read("Tests/AppTests/CardTests.swift") == RecordSessionTests.suiteSource)
        #expect(LastRun.load(repository: repo.url) == nil)
    }

    /// Ctrl-C during `rerecord`'s verification: the last run's failures stay as they were.
    @Test func ctrlCDuringARerecordsVerification() throws {
        let (repo, env, _) = try setUp()
        let time = try lastRunWithCardFailing(in: repo)
        let marker = testTemp("interrupt")
        let result = try snapkit.interrupted("rerecord", "--repo", repo.url.path, at: marker,
                                             environment: interrupting(env, at: "verify", marker: marker))
        let history = snapkit.history(of: repo.url).load()
        let (recorded, verified) = (try #require(history.first?.resultBundle), try #require(history.last?.resultBundle))
        #expect(Outcome(result) == Outcome(status: 1, stdout: rerecordingCard(time) + xcodebuild(recorded, only: "AppTests/CardTests") + failed
            + restored + "▸ Verifying new references\n" + xcodebuild(verified, only: "AppTests/CardTests") + """
            ▸ Testing
            ▸ Finished
            ▸ Done

            Recorded suites: AppTests/CardTests
            Patched and restored: Tests/AppTests/CardTests.swift
            Recorded; the verification was cancelled.

            """, stderr: interrupted))
        #expect(try repo.read(snapshot) == "new")
        #expect(LastRun.load(repository: repo.url)?.resultBundle == "/results/earlier.xcresult")
    }

    /// A check whose build failed, or that ran no test, has no verdicts: not "every test passes".
    @Test func aFlakinessCheckThatChecksNothing() throws {
        let (repo, env, _) = try setUp(buildError: true)
        let built = try snapkit("flaky", "--repo", repo.url.path, "--suite", "AppTests/CardTests", "--iterations", "3", environment: env)
        let bundle = try #require(snapkit.history(of: repo.url).load().last?.resultBundle)
        #expect(Outcome(built) == failure("Nothing was checked: the build failed (CardTests.swift:6:9: cannot find 'draw' in scope).",
            stdout: "snapkit: running AppTests/CardTests 3×\n" + environmentLine + xcodebuild(bundle, only: "AppTests/CardTests", extra: iterations(3))
                + (try buildFailed(in: repo)) + """

                Result: 0 passed, 0 failed, 0 skipped  [local]
                Build errors:
                  CardTests.swift:6:9: cannot find 'draw' in scope
                Result bundle: \(bundle)

                """))

        let (other, otherEnv, _) = try setUp()
        let none = try snapkit("flaky", "--repo", other.url.path, "--suite", "AppTests/NoSuchTests", "--iterations", "3", environment: otherEnv)
        let empty = try #require(snapkit.history(of: other.url).load().last?.resultBundle)
        #expect(Outcome(none) == failure("Nothing was checked: no test ran.",
            stdout: "snapkit: running AppTests/NoSuchTests 3×\n" + environmentLine + xcodebuild(empty, only: "AppTests/NoSuchTests", extra: iterations(3))
                + passed + "\nResult: 0 passed, 0 failed, 0 skipped  [local]\nResult bundle: \(empty)\n"))
    }

    // MARK: - On this Mac as the remote one

    /// `setUp`, for runs with `--remote local`: this Mac is the remote one, its checkout
    /// `remoteCheckout`, and `HOME` is `home`, where its preflight finds the Xcode. The project's
    /// own remote host is one that doesn't exist: `--remote local` replaces it.
    func setUpRemote(fail: Bool = false) throws -> (TempRepo, [String: String]) {
        let (repo, env, _) = try setUp(fail: fail)
        try repo.write(".snapshotkit.yml", try repo.read(".snapshotkit.yml") + "remoteHost: ci-mac.invalid\nremoteDirectory: \(remoteCheckout.path)\n")
        try repo.commitAll("remote")
        return (repo, env.merging(["HOME": home.path]) { $1 })
    }

    let remoteCheckout = testTemp("remote-checkout")

    /// What a run on this Mac as the remote one prints, around what `xcodebuild` printed.
    func remoteRun(_ bundle: String, only: String? = nil, extra: String = "", recording: Bool = false, output: String) -> String {
        "▸ Checking remote Xcode and simulator\nsnapkit: localhost: Xcode 99.0, Example Phone (iOS 99.0)\n▸ Syncing working tree\n"
            + "snapkit: synced working tree to localhost:\(remoteCheckout.path)\n" + (recording ? "▸ Enabling record mode on remote copy\n" : "")
            + "▸ Running tests remotely\n" + xcodebuild(bundle, only: only, extra: extra).replacingOccurrences(of: "$ xcodebuild", with: "$ [localhost] xcodebuild")
            + output + "▸ Collecting results\n" + (recording ? "snapkit: downloaded \(snapshot)\n" : "") + "▸ Done\n"
    }

    /// `run --remote`: the run is the last run, with the failure image downloaded, which
    /// `snapkit failures` lists though the result bundle stayed on the remote Mac.
    @Test func aRemoteRunAndItsFailures() throws {
        let (repo, env) = try setUpRemote(fail: true)
        let result = try snapkit("run", "--repo", repo.url.path, "--remote", "local", environment: env)
        let last = try #require(LastRun.load(repository: repo.url))
        let (bundle, images) = (try #require(last.resultBundle), try #require(last.attachmentsDirectory))
        #expect(bundle.hasPrefix(remoteCheckout.path + "/.snapshotkit/results/"))
        #expect(Outcome(result) == Outcome(status: 1, stdout: remoteRun(bundle, output: failed) + """

            Result: 0 passed, 1 failed, 0 skipped  [localhost]
            FAILING SUITE: AppTests/CardTests (1/1 tests)
              ✘ card()
            Result bundle: \(bundle)
            Failure images: 1 (see `snapkit failures`)

            """))
        #expect(last.host == "localhost")

        // As on another Mac, the bundle isn't here.
        try FileManager.default.removeItem(at: remoteCheckout.appendingPathComponent(".snapshotkit/results"))
        #expect(Outcome(try snapkit("failures", "--repo", repo.url.path, environment: env)) == Outcome(status: 0, stdout: """
            AppTests/CardTests
              ✘ card()  (1/1 repetitions failed)
                failure:    \(images)/F.png
                difference: —

            """))
        #expect(Outcome(try snapkit("failures", "--repo", repo.url.path, "--out", testTemp("out").path, environment: env)) == failure(
            "--out exports a result bundle, and the last run’s stayed on localhost. Leave out --out to list the images downloaded from there, "
                + "or pass --xcresult PATH."))
    }

    /// `rerecord --remote`: recorded there and the new reference downloaded, then verified there;
    /// the local test source is never patched.
    @Test func aRemoteRerecordDownloadsAndVerifies() throws {
        let (repo, env) = try setUpRemote()
        let time = try lastRunWithCardFailing(in: repo)
        let result = try snapkit("rerecord", "--repo", repo.url.path, "--remote", "local", environment: env)
        let history = snapkit.history(of: repo.url).load()
        #expect(history.map(\.kind) == [.record, .verify])
        let (recorded, verified) = (try #require(history.first?.resultBundle), try #require(history.last?.resultBundle))
        #expect(Outcome(result) == Outcome(status: 0, stdout: "snapkit: using failing suites from the last run (local, \(time))\n"
            + "snapkit: re-recording AppTests/CardTests\n" + remoteRun(recorded, only: "AppTests/CardTests", recording: true, output: failed)
            + "\nRecorded suites: AppTests/CardTests\nDownloaded 1 snapshot recorded on localhost.\n"
            + remoteRun(verified, only: "AppTests/CardTests", output: passed) + "Verified: 1 passed with the new references.\n"))
        #expect(try repo.read(snapshot) == "new")
        #expect(try repo.read("Tests/AppTests/CardTests.swift") == RecordSessionTests.suiteSource)
        #expect(LastRun.load(repository: repo.url)?.failingSuites.isEmpty == true)
    }

    @Test func aRemoteRerecordWithoutVerifying() throws {
        let (repo, env) = try setUpRemote()
        let time = try lastRunWithCardFailing(in: repo)
        let result = try snapkit("rerecord", "--repo", repo.url.path, "--remote", "local", "--no-verify", environment: env)
        let recorded = try #require(snapkit.history(of: repo.url).load().first?.resultBundle)
        #expect(Outcome(result) == Outcome(status: 0, stdout: "snapkit: using failing suites from the last run (local, \(time))\n"
            + "snapkit: re-recording AppTests/CardTests\n" + remoteRun(recorded, only: "AppTests/CardTests", recording: true, output: failed)
            + "\nRecorded suites: AppTests/CardTests\nDownloaded 1 snapshot recorded on localhost.\n"))
        #expect(snapkit.history(of: repo.url).load().map(\.kind) == [.record])
        #expect(try repo.read(snapshot) == "new")
    }

    /// Ctrl-C during the remote verification: what was recorded and downloaded stays.
    @Test func ctrlCDuringARemoteVerification() throws {
        let (repo, env) = try setUpRemote()
        let time = try lastRunWithCardFailing(in: repo)
        let marker = testTemp("interrupt")
        let result = try snapkit.interrupted("rerecord", "--repo", repo.url.path, "--remote", "local", at: marker,
                                             environment: interrupting(env, at: "verify", marker: marker))
        let history = snapkit.history(of: repo.url).load()
        let (recorded, verified) = (try #require(history.first?.resultBundle), try #require(history.last?.resultBundle))
        #expect(Outcome(result) == Outcome(status: 1, stdout: "snapkit: using failing suites from the last run (local, \(time))\n"
            + "snapkit: re-recording AppTests/CardTests\n" + remoteRun(recorded, only: "AppTests/CardTests", recording: true, output: failed)
            + "\nRecorded suites: AppTests/CardTests\nDownloaded 1 snapshot recorded on localhost.\n"
            + remoteRun(verified, only: "AppTests/CardTests", output: "▸ Testing\n▸ Finished\n") + "Recorded; the verification was cancelled.\n",
            stderr: interrupted))
        #expect(try repo.read(snapshot) == "new")
        #expect(LastRun.load(repository: repo.url)?.resultBundle == "/results/earlier.xcresult")
    }

    /// `flaky --remote` without a last run finds the failing suites with a run there too, not here.
    @Test func aRemoteFlakinessCheckWithoutALastRun() throws {
        let (repo, env) = try setUpRemote(fail: true)
        let result = try snapkit("flaky", "--repo", repo.url.path, "--remote", "local", "--iterations", "3", environment: env)
        let history = snapkit.history(of: repo.url).load()
        #expect(history.map(\.kind) == [.run, .flakeCheck])
        let (run, check) = (try #require(history.first?.resultBundle), try #require(history.last?.resultBundle))
        #expect(Outcome(result) == Outcome(status: 1, stdout: "snapkit: no previous run recorded; running tests to find failing suites\n"
            + remoteRun(run, output: failed) + """

            Result: 0 passed, 1 failed, 0 skipped  [localhost]
            FAILING SUITE: AppTests/CardTests (1/1 tests)
              ✘ card()
            Result bundle: \(run)
            snapkit: running AppTests/CardTests 3×

            """ + remoteRun(check, only: "AppTests/CardTests", extra: iterations(3), output: failed)
            + "\nFlaky              2✔ 1✘  AppTests/CardTests/card()\n"))
        #expect(LastRun.load(repository: repo.url)?.host == "localhost")
    }

    /// The environment that has `xcodebuild` wait for a Ctrl-C at `point` (see `setUp`).
    func interrupting(_ env: [String: String], at point: String, marker: URL, results: String = "") -> [String: String] {
        env.merging(["FAKE_INTERRUPT_AT": point, "FAKE_INTERRUPT_MARKER": marker.path, "FAKE_RESULTS": results]) { $1 }
    }

    let interrupted = "\nInterrupted — cancelling (press Ctrl-C again to force quit)…\n"

    /// It said "The operation couldn’t be completed. (Swift.CancellationError error 1.)". The lookup
    /// itself is stopped: `xcodebuild -list` can take minutes, resolving packages.
    @Test func ctrlCWhileTheSchemeIsLookedUpCancels() throws {
        let (repo, env, log) = try setUp()
        try repo.write(".snapshotkit.yml", try repo.read(".snapshotkit.yml").replacingOccurrences(of: "scheme: App\n", with: ""))
        let marker = testTemp("interrupt")
        let result = try snapkit.interrupted("run", "--repo", repo.url.path, at: marker,
                                             environment: interrupting(env, at: "list", marker: marker))
        #expect(Outcome(result) == Outcome(status: 1, stdout: environmentLine + "Cancelled.\n", stderr: interrupted))
        #expect(try String(contentsOf: log, encoding: .utf8) == "-list interrupted\n")
        #expect(LastRun.load(repository: repo.url) == nil)
    }

    /// `record` without a scheme to run: the run throws after the patch, which is undone all the same.
    @Test func aRecordThatCannotFindTheSchemeRestoresTheSource() throws {
        let (repo, env, _) = try setUp()
        try repo.write(".snapshotkit.yml", try repo.read(".snapshotkit.yml").replacingOccurrences(of: "scheme: App\n", with: ""))
        let result = try snapkit("record", "--repo", repo.url.path, "card",
                                 environment: env.merging(["FAKE_SCHEMES": #"{"project": {"schemes": []}}"#]) { $1 })
        #expect(Outcome(result) == failure(ConfigError.missingScheme.errorDescription!, stdout: recordingCard + restored))
        #expect(try repo.read("Tests/AppTests/CardTests.swift") == RecordSessionTests.suiteSource)
        #expect(!FileManager.default.fileExists(atPath: try RecordSession.journalURL(for: repo.url).path))
        #expect(snapkit.history(of: repo.url).load().isEmpty)
    }

    /// Ctrl-C while the patched suite's scheme is looked up: cancelled, and the source restored.
    @Test func ctrlCWhileARecordLooksUpTheSchemeRestoresTheSource() throws {
        let (repo, env, log) = try setUp()
        try repo.write(".snapshotkit.yml", try repo.read(".snapshotkit.yml").replacingOccurrences(of: "scheme: App\n", with: ""))
        let marker = testTemp("interrupt")
        let result = try snapkit.interrupted("record", "--repo", repo.url.path, "card", at: marker,
                                             environment: interrupting(env, at: "list", marker: marker))
        #expect(Outcome(result) == Outcome(status: 1, stdout: recordingCard + restored + "Cancelled.\n", stderr: interrupted))
        #expect(try String(contentsOf: log, encoding: .utf8) == "-list interrupted\n")
        #expect(try repo.read("Tests/AppTests/CardTests.swift") == RecordSessionTests.suiteSource)
        #expect(!FileManager.default.fileExists(atPath: try RecordSession.journalURL(for: repo.url).path))
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
