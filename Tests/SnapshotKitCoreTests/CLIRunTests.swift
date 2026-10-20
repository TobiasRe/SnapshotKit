import Foundation
import Testing
@testable import SnapshotKitCore

/// A repository whose `.snapshotkit.yml` names an Xcode that isn't there: commands that would run
/// tests get as far as checking it, which shows what they chose to run, and stop with exit 2.
private func repoWithCardTests() throws -> TempRepo {
    let repo = try TempRepo()
    try repo.write(".snapshotkit.yml", "scheme: App\ndevice: Example Phone\ndeveloperDir: /no/such/Xcode.app\n")
    try repo.write("Tests/AppTests/CardTests.swift", RecordSessionTests.suiteSource)
    try repo.write("Tests/AppTests/__Snapshots__/CardTests/card.1.png", png(width: 2, height: 2, rgba: (255, 0, 0, 255)))
    try repo.write("Tests/AppTests/__Snapshots__/CardTests/gone.1.png", png(width: 2, height: 2, rgba: (255, 0, 0, 255)))
    try repo.commitAll("init")
    return repo
}

private let noXcode = "Xcode at `/no/such/Xcode.app` does not exist. Install it there or set `xcode:` / `developerDir:` in `.snapshotkit.yml`."

private func lastRun(_ outcome: TestOutcome, host: String = "local", bundle: String = "/results/run.xcresult") -> TestRunResult {
    let suite = SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [
        TestCaseResult(name: "card()", identifier: "CardTests/card()", outcome: outcome, failureMessages: [], repetitions: [outcome]),
    ], failureFiles: [])
    var result = TestRunResult(commandLine: "", exitStatus: outcome == .failed ? 65 : 0, cancelled: false, resultBundle: URL(fileURLWithPath: bundle),
                               summary: TestRunSummary(suites: [suite]), passed: outcome == .passed ? 1 : 0,
                               failed: outcome == .failed ? 1 : 0, skipped: 0, buildErrors: [])
    result.host = host
    return result
}

@Suite struct CLIRecordTests {
    let snapkit = Snapkit()

    @Test func recordNamesWhatItWillRecordBeforeCheckingXcode() throws {
        let repo = try repoWithCardTests()
        #expect(Outcome(try snapkit("record", "--repo", repo.url.path, "card"))
                == failure(noXcode, status: 2, stdout: "snapkit: recording AppTests/CardTests/card()\n"))
        #expect(Outcome(try snapkit("record", "--repo", repo.url.path, "card", "--whole-suite"))
                == failure(noXcode, status: 2, stdout: "snapkit: recording AppTests/CardTests\n"))
        // Nothing was patched.
        #expect(try repo.read("Tests/AppTests/CardTests.swift") == RecordSessionTests.suiteSource)
        #expect(!FileManager.default.fileExists(atPath: try RecordSession.journalURL(for: repo.url).path))
    }

    /// Orphans are left out: their test is gone, so there is nothing to record them.
    @Test func recordWithoutAMatch() throws {
        let repo = try repoWithCardTests()
        #expect(Outcome(try snapkit("record", "--repo", repo.url.path, "card", "dark")) == failure("No snapshot path contains “card” and “dark”."))
        #expect(Outcome(try snapkit("record", "--repo", repo.url.path, "gone")) == failure("No snapshot path contains “gone”."))
    }

    /// Not "no previous run recorded" and every test run again to find failures there aren't.
    @Test func rerecordWithNothingFailing() throws {
        let repo = try repoWithCardTests()
        LastRun.update(with: lastRun(.passed), repository: repo.url)
        #expect(Outcome(try snapkit("rerecord", "--repo", repo.url.path)) == Outcome(status: 0, stdout: "Nothing to re-record: no failing suites.\n"))
        #expect(Outcome(try snapkit("flaky", "--repo", repo.url.path)) == Outcome(status: 0, stdout: "No failing suites to check.\n"))
    }

    @Test func rerecordUsesTheFailingSuitesOfTheLastRun() throws {
        let repo = try repoWithCardTests()
        LastRun.update(with: lastRun(.failed), repository: repo.url)
        let time = try #require(LastRun.load(repository: repo.url)).date.formatted(date: .omitted, time: .shortened)
        #expect(Outcome(try snapkit("rerecord", "--repo", repo.url.path)) == failure(noXcode, status: 2, stdout: """
            snapkit: using failing suites from the last run (local, \(time))
            snapkit: re-recording AppTests/CardTests

            """))
        // A bare suite name works when the last run had it.
        #expect(Outcome(try snapkit("rerecord", "--repo", repo.url.path, "--suite", "CardTests"))
                == failure(noXcode, status: 2, stdout: "snapkit: re-recording AppTests/CardTests\n"))
        #expect(Outcome(try snapkit("rerecord", "--repo", repo.url.path, "--suite", "AppTests/ListTests", "--suite", "CardTests"))
                == failure(noXcode, status: 2, stdout: "snapkit: re-recording AppTests/ListTests, AppTests/CardTests\n"))
    }

    /// `--iterations`, else the app's setting.
    @Test func flakyRunsTheFailingSuitesTheChosenNumberOfTimes() throws {
        let repo = try repoWithCardTests()
        LastRun.update(with: lastRun(.failed), repository: repo.url)
        let time = try #require(LastRun.load(repository: repo.url)).date.formatted(date: .omitted, time: .shortened)
        snapkit.settings.update { $0.flakeIterations = 7 }
        #expect(Outcome(try snapkit("flaky", "--repo", repo.url.path)) == failure(noXcode, status: 2, stdout: """
            snapkit: using failing suites from the last run (local, \(time))
            snapkit: running AppTests/CardTests 7×

            """))
        #expect(Outcome(try snapkit("flaky", "--repo", repo.url.path, "--iterations", "3", "--suite", "AppTests/CardTests"))
                == failure(noXcode, status: 2, stdout: "snapkit: running AppTests/CardTests 3×\n"))
    }
}

/// A record patch as a crashed `snapkit` leaves it: the patched source and its journal, owned by
/// process `owner`. Written by hand rather than with `RecordSession.begin`, which would register it
/// with this test process, whose `RecordSessionTests` restore whatever is registered.
private func leaveRecordPatch(in repo: TempRepo, owner: Int32 = 999_999) throws {
    let path = "Tests/AppTests/CardTests.swift"
    let original = try repo.read(path)
    let patched = try RecordPatcher.patch(source: original, suite: "CardTests", file: path)
    try repo.write(path, patched)
    let journal = PatchJournal(repository: repo.url.path, createdAt: Date(), processIdentifier: owner,
                               files: [PatchedFile(path: path, suite: "CardTests", original: original, patched: patched)])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let url = try RecordSession.journalURL(for: repo.url)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(journal).write(to: url)
}

@Suite struct CLIRestoreTests {
    let snapkit = Snapkit()

    @Test func restoreUndoesALeftoverPatch() throws {
        let repo = try repoWithCardTests()
        #expect(Outcome(try snapkit("restore", "--repo", repo.url.path)) == Outcome(status: 0, stdout: "No record patch to restore.\n"))
        try leaveRecordPatch(in: repo)
        #expect(Outcome(try snapkit("restore", "--repo", repo.url.path)) == Outcome(status: 0, stdout: "restored Tests/AppTests/CardTests.swift\n"))
        #expect(try repo.read("Tests/AppTests/CardTests.swift") == RecordSessionTests.suiteSource)
        #expect(Outcome(try snapkit("restore", "--repo", repo.url.path)) == Outcome(status: 0, stdout: "No record patch to restore.\n"))
    }

    @Test func restoreRefusesWhileARunningSnapkitOwnsThePatch() throws {
        let repo = try repoWithCardTests()
        let owner = try RecordSessionTests.startProcess(named: "snapkit")
        defer { owner.terminate() }
        try leaveRecordPatch(in: repo, owner: owner.processIdentifier)
        #expect(Outcome(try snapkit("restore", "--repo", repo.url.path)) == failure("A re-record is already in progress for \(repo.root)."))
        #expect(try repo.read("Tests/AppTests/CardTests.swift") != RecordSessionTests.suiteSource)
        #expect(Outcome(try snapkit("restore", "--repo", repo.url.path, "--force"))
                == Outcome(status: 0, stdout: "restored Tests/AppTests/CardTests.swift\n"))
        #expect(try repo.read("Tests/AppTests/CardTests.swift") == RecordSessionTests.suiteSource)
    }

    /// "Every command first restores record patches left behind … in any registered project, not
    /// only this one — and says so."
    @Test func everyCommandFirstRestoresLeftoversInEveryRegisteredProject() throws {
        let patched = try repoWithCardTests(), other = try TempRepo()
        try leaveRecordPatch(in: patched)
        let registry = snapkit.home.appendingPathComponent("active-patches.json")
        try FileManager.default.createDirectory(at: snapkit.home, withIntermediateDirectories: true)
        try JSONEncoder().encode([patched.url.path]).write(to: registry)

        #expect(Outcome(try snapkit("history", "--repo", other.url.path)) == Outcome(status: 0, stdout: "No flaky signals.\n", stderr: """
            snapkit: restored leftover record patch in \(patched.url.path):
              restored Tests/AppTests/CardTests.swift

            """))
        #expect(try patched.read("Tests/AppTests/CardTests.swift") == RecordSessionTests.suiteSource)
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: registry)).isEmpty)
        #expect(Outcome(try snapkit("history", "--repo", other.url.path)) == Outcome(status: 0, stdout: "No flaky signals.\n"))
    }
}

@Suite struct CLIHistoryTests {
    let snapkit = Snapkit()
    let commit = "0123456789abcdef0123456789abcdef01234567"

    func record(_ outcome: TestOutcome, host: String = "local", minutes: Double, dirty: Bool = false) -> RunRecord {
        var r = RunRecord(date: Date(timeIntervalSince1970: 1_792_000_000 + minutes * 60), kind: .run, host: host, commit: commit, branch: "main",
                          dirty: dirty, summary: nil, passed: outcome == .passed ? 1 : 0, failed: outcome == .failed ? 1 : 0, skipped: 0,
                          resultBundle: nil)
        r.outcomes = ["AppTests/CardTests/card()": [outcome]]
        return r
    }

    func date(_ minutes: Double) -> String {
        Date(timeIntervalSince1970: 1_792_000_000 + minutes * 60).formatted(date: .numeric, time: .shortened)
    }

    @Test func noRunsYet() throws {
        let repo = try TempRepo()
        #expect(Outcome(try snapkit("history", "--repo", repo.url.path)) == Outcome(status: 0, stdout: "No flaky signals.\n"))
        #expect(Outcome(try snapkit("history", "--repo", repo.url.path, "AppTests/CardTests/card()"))
                == Outcome(status: 0, stdout: "No flaky signals.\nNo runs of AppTests/CardTests/card() recorded.\n"))
    }

    @Test func runsFlakySignalsAndOneTestsStrip() throws {
        let repo = try TempRepo()
        let history = snapkit.history(of: repo.url)
        history.append(record(.passed, minutes: 0))
        history.append(record(.failed, host: "ci-mac", minutes: 1))
        history.append(record(.failed, minutes: 2, dirty: true))
        let runs = """
            \(date(0))  run        local        1✔ 0✘  01234567
            \(date(1))  run        ci-mac       0✔ 1✘  01234567
            \(date(2))  run        local        0✔ 1✘  01234567+dirty
            Flaky (passed and failed on the same commit):
              AppTests/CardTests/card()  1✔ 1✘  failing on: ci-mac
                ✔ ✘ ✘

            """
        #expect(Outcome(try snapkit("history", "--repo", repo.url.path)) == Outcome(status: 0, stdout: runs))
        #expect(Outcome(try snapkit("history", "--repo", repo.url.path, "AppTests/CardTests/card()")) == Outcome(status: 0, stdout: runs + """
            AppTests/CardTests/card(): ✔ ✘ ✘
              \(date(0))  passed  run  local  01234567
              \(date(1))  failed  run  ci-mac  01234567
              \(date(2))  failed  run  local  01234567

            """))
    }

    @Test func listsTheLast15Runs() throws {
        let repo = try TempRepo()
        let history = snapkit.history(of: repo.url)
        for i in 0..<20 { history.append(record(.passed, minutes: Double(i))) }
        let lines = try snapkit("history", "--repo", repo.url.path).stdout.split(separator: "\n")
        #expect(lines.count == 16)
        #expect(lines.first?.hasPrefix(date(5) + "  ") == true)
        #expect(lines.last == "No flaky signals.")
    }
}

/// `failures` reads result bundles with `xcrun xcresulttool`; a stand-in on the PATH serves a
/// bundle's `tests.json` and copies its `attachments` folder as the export.
@Suite struct CLIFailuresTests {
    let snapkit = Snapkit()
    let reference = "Tests/AppTests/__Snapshots__/CardTests/card.1.png"

    func fakeXcrun() throws -> [String: String] {
        let bin = testTemp("fake-xcrun")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("xcrun")
        try """
            #!/bin/bash
            case "$1 $2" in
              "xcresulttool get") while [ "$1" != --path ]; do shift; done; cat "$2/tests.json" ;;
              "xcresulttool export") while [ "$1" != --path ]; do shift; done; bundle=$2
                while [ "$1" != --output-path ]; do shift; done; cp "$bundle"/attachments/* "$2"/ ;;
              *) echo "unexpected: xcrun $*" >&2; exit 64 ;;
            esac

            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return ["PATH": "\(bin.path):/usr/bin:/bin"]
    }

    /// A CI artifact: `card()` failed, its reference white and the new image with three red pixels.
    func bundle(named name: String = "CI", failing: Bool = true, repo: TempRepo) throws -> URL {
        let bundle = testTemp("artifacts").appendingPathComponent("\(name).xcresult")
        let attachments = bundle.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let message = "Snapshot does not match reference.\n\n@\u{2212}\n\"file://\(repo.root)/\(reference)\"\n@+\n\"file:///tmp/CardTests/card.1.png\""
        let card: [String: Any] = ["name": "card()", "nodeType": "Test Case", "nodeIdentifier": "CardTests/card()", "result": failing ? "Failed" : "Passed",
                                   "children": failing ? [["name": message, "nodeType": "Failure Message"]] : []]
        let tests: [String: Any] = ["testNodes": [["name": "App", "nodeType": "Test Plan", "children": [
            ["name": "AppTests", "nodeType": "Unit test bundle", "children": [
                ["name": "CardTests", "nodeType": "Test Suite", "children": [card,
                    ["name": "row()", "nodeType": "Test Case", "nodeIdentifier": "CardTests/row()", "result": "Passed"]]]]]]]]]
        try JSONSerialization.data(withJSONObject: tests).write(to: bundle.appendingPathComponent("tests.json"))
        var manifest: [[String: Any]] = []
        if failing {
            let white = PixelImage(width: 10, height: 10, pixels: Array(repeating: 255, count: 400))
            var red = white
            for i in 0..<3 { red.pixels[i * 4 + 1] = 0; red.pixels[i * 4 + 2] = 0 }
            try white.pngData()!.write(to: attachments.appendingPathComponent("R.png"))
            try red.pngData()!.write(to: attachments.appendingPathComponent("F.png"))
            try white.pngData()!.write(to: attachments.appendingPathComponent("D.png"))
            manifest = [["testIdentifier": "CardTests/card()", "attachments": [
                ["exportedFileName": "R.png", "suggestedHumanReadableName": "reference_0_A.png", "repetitionNumber": 1],
                ["exportedFileName": "F.png", "suggestedHumanReadableName": "failure_0_B.png", "repetitionNumber": 1],
                ["exportedFileName": "D.png", "suggestedHumanReadableName": "difference_0_C.png", "repetitionNumber": 1],
            ]]]
        }
        try JSONSerialization.data(withJSONObject: manifest).write(to: attachments.appendingPathComponent("manifest.json"))
        return bundle
    }

    @Test func listsTheFailuresOfABundleWithImagesDiagnosisAndRecentRuns() throws {
        let repo = try TempRepo()
        let env = try fakeXcrun()
        let ci = try bundle(repo: repo)
        let history = snapkit.history(of: repo.url)
        for outcome in [TestOutcome.passed, .failed] {
            var run = RunRecord(kind: .run, host: "local", commit: "c", branch: "b", dirty: false, summary: nil,
                                passed: 0, failed: 0, skipped: 0, resultBundle: nil)
            run.outcomes = ["AppTests/CardTests/card()": [outcome]]
            history.append(run)
        }
        let exported = ci.deletingPathExtension().path + ".attachments"
        let expected = Outcome(status: 0, stdout: """
            AppTests/CardTests
              ✘ card()  (1/1 repetitions failed)
                reference: \(reference)
                failure:    \(exported)/F.png
                difference: \(exported)/D.png
                Visible change in a 3×1 area at 0, 0.
                recent runs: ✔ ✘

            """)
        #expect(Outcome(try snapkit("failures", "--repo", repo.url.path, "--xcresult", ci.path, environment: env)) == expected)
        #expect(FileManager.default.fileExists(atPath: exported + "/F.png"))
        // Imported into the history once, however often it is listed.
        _ = try snapkit("failures", "--repo", repo.url.path, "--xcresult", ci.path, environment: env)
        let imported = history.load().filter { $0.kind == .imported }
        #expect(imported.map(\.host) == ["CI.xcresult"])
        #expect(imported.first?.failed == 1 && imported.first?.passed == 1)
    }

    @Test func exportsWhereItIsTold() throws {
        let repo = try TempRepo()
        let out = testTemp("snapshot-failures")
        let result = try snapkit("failures", "--repo", repo.url.path, "--xcresult", try bundle(repo: repo).path, "--out", out.path,
                                 environment: try fakeXcrun())
        #expect(result.status == 0)
        #expect(result.stdout.contains("\n    failure:    \(out.path)/F.png\n    difference: \(out.path)/D.png\n"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == ["D.png", "F.png", "R.png", "manifest.json"])
    }

    @Test func aBundleWithoutFailures() throws {
        let repo = try TempRepo()
        let passed = try bundle(named: "Passed", failing: false, repo: repo)
        #expect(Outcome(try snapkit("failures", "--repo", repo.url.path, "--xcresult", passed.path, environment: try fakeXcrun()))
                == Outcome(status: 0, stdout: "No failing tests in Passed.xcresult.\n"))
    }

    @Test func withoutALocalBundle() throws {
        let repo = try TempRepo()
        let none = failure("No local result bundle. Pass --xcresult PATH (e.g. a CI artifact).")
        #expect(Outcome(try snapkit("failures", "--repo", repo.url.path)) == none)
        // The last run was remote: its bundle never was here.
        LastRun.update(with: lastRun(.failed, host: "ci-mac", bundle: "/Users/ci/results/run.xcresult"), repository: repo.url)
        #expect(Outcome(try snapkit("failures", "--repo", repo.url.path)) == none)
        LastRun.update(with: lastRun(.failed, bundle: "/gone/run.xcresult"), repository: repo.url)
        #expect(Outcome(try snapkit("failures", "--repo", repo.url.path))
                == failure("The last run’s results are gone (/gone/run.xcresult). Run the tests again (`snapkit run`), or pass --xcresult PATH."))
    }
}
