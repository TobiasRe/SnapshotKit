import Foundation
import Testing
@testable import SnapshotKitCore

/// GitLab answering from a dictionary of API paths.
struct FakeGitLab: GitLabAPI {
    var responses: [String: Data]

    init(_ responses: [String: String]) {
        self.responses = responses.mapValues { Data($0.utf8) }
    }

    func get(_ path: String) throws -> Data {
        guard let data = responses[path] else { throw GitLabError.request(path: path, output: "404 Not Found") }
        return data
    }
}

@Suite(.isolated) struct GitLabLinkTests {
    @Test func readsAJobsURL() {
        let link = GitLabLink.job(url: "https://gitlab.example.com/mobile/ios/shop/-/jobs/4567")
        #expect(link == GitLabLink(host: "gitlab.example.com", projectPath: "mobile/ios/shop", jobID: 4567))
        #expect(GitLabLink.job(url: " gitlab.example.com/a/b/-/jobs/1/raw?x=1#L2\n")?.jobID == 1)
        #expect(GitLabLink.job(url: "https://gitlab.example.com:8443/a/b/-/jobs/2")?.host == "gitlab.example.com:8443")
        #expect(GitLabLink.job(url: "https://gitlab.example.com/a/b/-/pipelines/3") == nil)
        #expect(GitLabLink.job(url: "https://gitlab.example.com/-/jobs/3") == nil)
        #expect(link?.projectID == "mobile%2Fios%2Fshop")
        #expect(link?.jobURL == "https://gitlab.example.com/mobile/ios/shop/-/jobs/4567")
    }

    @Test(arguments: [
        "git@gitlab.example.com:mobile/ios/shop.git",
        "ssh://git@gitlab.example.com:2222/mobile/ios/shop.git",
        "https://gitlab.example.com/mobile/ios/shop.git",
        "https://ci-token@gitlab.example.com/mobile/ios/shop",
    ])
    func readsARemote(_ remote: String) {
        #expect(GitLabLink.remote(remote) == GitLabLink(host: "gitlab.example.com", projectPath: "mobile/ios/shop"))
    }

    @Test func refusesWhatIsNoProject() {
        #expect(GitLabLink.remote("/local/clone") == nil)
        #expect(GitLabLink.remote("git@gitlab.example.com:shop.git") == nil)
    }
}

@Suite(.isolated) struct SnapshotMismatchTests {
    static let report = try! JSONDecoder.gitLab.decode(CITestReport.self, from: try! fixture("gitlab-test-report.json"))
    static func message(_ name: String) -> String { report.testSuites[0].testCases.first { $0.name == name }!.message }

    @Test func readsThePathsAndThePrecisions() {
        let mismatches = SnapshotMismatch.parse(Self.message("testPayButton"))
        #expect(mismatches.count == 1)
        #expect(mismatches[0].reference == "/Users/ci-runner/builds/x1Y2z3/0/mobile/ios/shop/Example/ShopSnapshotTests/__Snapshots__/CardTests/testPayButton.1.png")
        #expect(mismatches[0].actual?.hasSuffix("/data/tmp/CardTests/testPayButton.1.png") == true)
        #expect(mismatches[0].pixels == .init(actual: 0.9935, required: 1))
        #expect(mismatches[0].perceptual == .init(actual: 0.365, required: 0.98))
        #expect(mismatches[0].metrics == ["0.65% of pixels differ, none may", "worst pixel matches 0.365, 0.98 required"])
        #expect(SnapshotMismatch.headline(of: Self.message("testPayButton")) == "0.65% of pixels differ, none may")
    }

    @Test func readsASizeMismatch() {
        let mismatch = SnapshotMismatch.parse(Self.message("testSummary"))[0]
        #expect(mismatch.metrics == ["Size 390×844, reference 390×800"])
        #expect(mismatch.reference?.hasSuffix("CheckoutTests/testSummary.dark.png") == true)
    }

    /// swift-snapshot-testing before 1.12 worded the numbers differently; a diff tool names the images on its command line.
    @Test func readsOlderWordingAndADiffTool() {
        let message = """
        Snapshot does not match reference.

        ksdiff "/ci/app/__Snapshots__/CardTests/card.1.png" "/ci/tmp/CardTests/card.1.png"

        Newly-taken snapshot does not match reference.
        Actual image precision 0.98 is less than required 0.99
        Actual perceptual precision 0.9 is less than required 1.0
        """
        let mismatch = SnapshotMismatch.parse(message)
        #expect(mismatch == [SnapshotMismatch(reference: "/ci/app/__Snapshots__/CardTests/card.1.png", actual: "/ci/tmp/CardTests/card.1.png",
                                              pixels: .init(actual: 0.98, required: 0.99), perceptual: .init(actual: 0.9, required: 1))])
        #expect(mismatch[0].metrics == ["2% of pixels differ, 1% may", "worst pixel matches 0.9, 1 required"])
    }

    /// Each assertion's numbers follow its own pair of images.
    @Test func keepsTwoAssertionsApart() {
        let one = "@−\n\"file:///r/__Snapshots__/S/a.1.png\"\n@+\n\"file:///t/S/a.1.png\"\nThe percentage of pixels that match 0.5 is less than required 1.0\n"
        let two = "@−\n\"file:///r/__Snapshots__/S/a.2.png\"\n@+\n\"file:///t/S/a.2.png\"\nThe lowest perceptual color precision 0.7 is less than required 0.9\n"
        let mismatches = SnapshotMismatch.parse(one + "\n" + two)
        #expect(mismatches.map(\.reference) == ["/r/__Snapshots__/S/a.1.png", "/r/__Snapshots__/S/a.2.png"])
        #expect(mismatches.map(\.pixels) == [.init(actual: 0.5, required: 1), nil])
        #expect(mismatches.map(\.perceptual) == [nil, .init(actual: 0.7, required: 0.9)])
    }

    @Test func aMessageWithoutImagesKeepsItsFirstLine() {
        #expect(SnapshotMismatch.parse("XCTAssertEqual failed: (\"12\") is not equal to (\"13\")").isEmpty)
        #expect(SnapshotMismatch.headline(of: "\n  XCTAssertEqual failed\nmore") == "XCTAssertEqual failed")
    }
}

@Suite(.isolated) struct CITraceTests {
    @Test func readsTheLog() throws {
        let trace = CITrace(log: String(decoding: try fixture("gitlab-job-trace.log"), as: UTF8.self))
        #expect(trace.scheme == "ShopSnapshotTests")
        #expect(trace.failingTests == [.init(bundle: "ShopSnapshotTests", suite: ["CardTests"], name: "testPayButton()"),
                                       .init(bundle: "ShopSnapshotTests", suite: ["CheckoutTests"], name: "testSummary()")])
        #expect(trace.resultBundle == "/Users/ci-runner/builds/x1Y2z3/0/mobile/ios/shop/build/Snapshots.xcresult")
        #expect(trace.projectDirectory == "/Users/ci-runner/builds/x1Y2z3/0/mobile/ios/shop")
    }

    @Test func readsAListNotGroupedByTarget() {
        let trace = CITrace(log: "Failing tests:\n\tAllSnapshots.CardTests.card()\n\n** TEST FAILED **\n")
        #expect(trace.failingTests == [.init(bundle: nil, suite: ["AllSnapshots", "CardTests"], name: "card()")])
    }

    /// The target is in front of the class (`Bundle.Suite`), or only in the log's list.
    @Test func findsAFailuresTarget() {
        let listed = [CITrace.Test(bundle: "AppTests", suite: ["AllSnapshots", "CardTests"], name: "card()")]
        func failure(_ classname: String, _ log: [CITrace.Test] = []) -> CIFailure {
            CIFailure(case: .init(status: "failed", name: "card", classname: classname), failingTests: log)
        }
        #expect(failure("AllSnapshots.CardTests", listed) == CIFailure(bundle: "AppTests", suite: ["AllSnapshots", "CardTests"], name: "card()", message: ""))
        #expect(failure("AppTests.AllSnapshots.CardTests", listed).suite == ["AllSnapshots", "CardTests"])
        #expect(failure("AppTests.CardTests") == CIFailure(bundle: "AppTests", suite: ["CardTests"], name: "card()", message: ""))
        #expect(failure("CardTests") == CIFailure(bundle: nil, suite: ["CardTests"], name: "card()", message: ""))
        #expect(failure("CardTests").identifier == "CardTests/card()")
    }
}

@Suite(.isolated) struct CIImporterTests {
    let runner = testTemp("runner")
    let directory = testTemp("ci-import")
    let link = GitLabLink(host: "gitlab.example.com", projectPath: "mobile/ios/shop", jobID: 4567)
    let pay = "Example/ShopSnapshotTests/__Snapshots__/CardTests/testPayButton.1.png"
    let summary = "Example/ShopSnapshotTests/__Snapshots__/CheckoutTests/testSummary.dark.png"
    var tmp: String { "Library/Developer/CoreSimulator/Devices/7F3C1E2A-0000-4000-8000-000000000001/data/tmp" }

    /// A repository with the references committed, then one re-recorded in the working tree, and the runner's
    /// folder with the image `testPayButton` took (that of `testSummary` is gone).
    func setUp(commitKnown: Bool = true) throws -> (TempRepo, FakeGitLab) {
        let repo = try TempRepo()
        try repo.write(pay, "committed pay")
        try repo.write(summary, "committed summary")
        try repo.commitAll("references")
        let sha = commitKnown ? try repo.git.run(["rev-parse", "HEAD"]) : String(repeating: "f", count: 40)
        try repo.write(pay, "re-recorded pay")
        let actual = runner.appendingPathComponent("\(tmp)/CardTests/testPayButton.1.png")
        try FileManager.default.createDirectory(at: actual.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("actual pay".utf8).write(to: actual)

        func onRunner(_ name: String) throws -> String {
            String(decoding: try fixture(name), as: UTF8.self).replacingOccurrences(of: "/Users/ci-runner", with: runner.path)
        }
        let api = FakeGitLab([
            "projects/mobile%2Fios%2Fshop/jobs/4567": """
                {"id": 4567, "name": "snapshotTest", "status": "failed", "stage": "test", "ref": "feature/checkout",
                 "web_url": "https://gitlab.example.com/mobile/ios/shop/-/jobs/4567", "commit": {"id": "\(sha)", "title": "Checkout"},
                 "pipeline": {"id": 89, "sha": "\(sha)"}, "runner": {"id": 3, "description": "ci-mac-1"},
                 "finished_at": "2026-10-26T08:22:02.120Z"}
                """,
            "projects/mobile%2Fios%2Fshop/jobs/4567/trace": try onRunner("gitlab-job-trace.log"),
            "projects/mobile%2Fios%2Fshop/pipelines/89/test_report": try onRunner("gitlab-test-report.json"),
            "projects/mobile%2Fios%2Fshop/merge_requests?state=opened&source_branch=feature%2Fcheckout":
                #"[{"iid": 12, "title": "Checkout", "web_url": "https://gitlab.example.com/mobile/ios/shop/-/merge_requests/12"}]"#,
        ])
        return (repo, api)
    }

    func importer(_ repo: TempRepo, _ api: FakeGitLab, login: String? = nil, destinations: Destinations? = nil) -> CIImporter {
        var importer = CIImporter(api: api, repository: repo.url, login: login)
        importer.transport = { destination in
            destinations?.append(destination)
            return LocalDirectoryTransport()
        }
        return importer
    }

    @Test func loadsTheFailuresWithTheirReferencesAndImages() throws {
        let (repo, api) = try setUp()
        let destinations = Destinations()
        let result = try importer(repo, api, destinations: destinations).load(link, into: directory)

        #expect(result.job.name == "snapshotTest")
        #expect(result.mergeRequest?.iid == 12)
        #expect(result.trace.scheme == "ShopSnapshotTests")
        // The snapshot job's failures only, not the unit tests'.
        #expect(result.summary.suites.map(\.identifier) == ["ShopSnapshotTests/CardTests", "ShopSnapshotTests/CheckoutTests"])
        #expect(result.summary.suites.flatMap(\.tests).map(\.identifier) == ["CardTests/testPayButton()", "CheckoutTests/testSummary()"])
        #expect(result.passed == 1)
        #expect(destinations.all == ["ci-mac-1"])

        let images = Dictionary(uniqueKeysWithValues: result.images.map { ($0.testIdentifier, $0) })
        // The reference as the job saw it, not as re-recorded since.
        #expect(try images["CardTests/testPayButton()"]?.reference.map { try String(contentsOf: $0, encoding: .utf8) } == "committed pay")
        #expect(try images["CardTests/testPayButton()"]?.failure.map { try String(contentsOf: $0, encoding: .utf8) } == "actual pay")
        #expect(images["CardTests/testPayButton()"]?.referencePath == pay)
        #expect(images["CardTests/testPayButton()"]?.bundle == "ShopSnapshotTests")
        #expect(images["CheckoutTests/testSummary()"]?.reference != nil)
        #expect(images["CheckoutTests/testSummary()"]?.failure == nil)
        #expect(result.notes == ["1 of the 2 images the tests took is no longer on ci-mac-1: it removes them when its next job starts. "
                                 + "Run the job again to see it."])
    }

    @Test func aLoginIsTheUserOnTheRunnerUnlessItNamesAHost() {
        #expect(CIImporter.destination(login: nil, runner: "ci-mac-1") == "ci-mac-1")
        #expect(CIImporter.destination(login: " ", runner: "ci-mac-1") == "ci-mac-1")
        #expect(CIImporter.destination(login: "builder", runner: "ci-mac-1") == "builder@ci-mac-1")
        #expect(CIImporter.destination(login: "builder@ci-mac-1.example.com", runner: "ci-mac-1") == "builder@ci-mac-1.example.com")
    }

    @Test func aCommitMissingHereTakesTheWorkingTreesReferences() throws {
        let (repo, api) = try setUp(commitKnown: false)
        let result = try importer(repo, api).load(link, into: directory)
        let reference = try #require(result.images.first { $0.testIdentifier == "CardTests/testPayButton()" }?.reference)
        #expect(try String(contentsOf: reference, encoding: .utf8) == "re-recorded pay")
        #expect(result.notes.first?.hasPrefix("The job’s commit ffffffff isn’t in this clone") == true)
    }

    @Test func withoutImagesNothingIsCopied() throws {
        let (repo, api) = try setUp()
        let destinations = Destinations()
        var importer = importer(repo, api, destinations: destinations)
        importer.fetchImages = false
        let result = try importer.load(link, into: directory)
        #expect(destinations.all.isEmpty)
        #expect(result.images.allSatisfy { $0.failure == nil && $0.reference != nil })
        #expect(result.notes.isEmpty)
    }

    /// No JUnit report: the log still names the failing tests.
    @Test func withoutATestReportTheLogNamesTheFailures() throws {
        let (repo, api) = try setUp()
        var bare = api
        bare.responses["projects/mobile%2Fios%2Fshop/pipelines/89/test_report"] = Data(#"{"test_suites": []}"#.utf8)
        let result = try importer(repo, bare).load(link, into: directory)
        #expect(result.summary.suites.map(\.identifier) == ["ShopSnapshotTests/CardTests", "ShopSnapshotTests/CheckoutTests"])
        #expect(result.images.isEmpty)
        #expect(result.notes.count == 1 && result.notes[0].contains("uploaded no test report"))
    }

    @Test func sshProblemsBecomeHints() {
        let importer = CIImporter(api: FakeGitLab([:]), repository: URL(fileURLWithPath: "/"))
        let paths = ["/Users/ci-runner/Library/Developer/CoreSimulator/Devices/X/data/tmp/a.png"]
        func hint(_ output: String, login: String? = nil) -> String {
            var importer = importer
            importer.login = login
            return importer.sshHint(for: RemoteError.commandFailed(host: "ci-mac-1", script: "", status: 255, output: output),
                                    destination: CIImporter.destination(login: login, runner: "ci-mac-1"), runner: "ci-mac-1", paths: paths)
        }
        #expect(hint("Host key verification failed.") == "ci-mac-1 isn’t a known SSH host yet, and SnapshotKit never trusts one by itself. "
                + "Connect once with `ssh ci-mac-1 true` and accept its key, then load the job again.")
        #expect(hint("ci@ci-mac-1: Permission denied (publickey).") == "ci-mac-1 refused the SSH login, so the images the tests took couldn’t be "
                + "copied. The images are in /Users/ci-runner/: set CI login in the Run tab to `ci-runner`.")
        #expect(hint("Permission denied (publickey).", login: "builder").hasSuffix("that `ssh builder@ci-mac-1 true` works without a password."))
        #expect(hint("Connection timed out").hasPrefix("Couldn’t copy the images the tests took from ci-mac-1: "))
    }
}

@Suite(.isolated) struct CIDetectorTests {
    func repo(branch: String = "feature/checkout") throws -> TempRepo {
        let repo = try TempRepo(branch: branch)
        try repo.write("README.md", "shop")
        try repo.commitAll("init")
        try repo.git.run(["remote", "add", "origin", "git@gitlab.example.com:mobile/ios/shop.git"])
        return repo
    }

    let api = FakeGitLab([
        "projects/mobile%2Fios%2Fshop/merge_requests?state=opened&source_branch=feature%2Fcheckout":
            #"[{"iid": 11, "title": "Older"}, {"iid": 12, "title": "Checkout"}]"#,
        "projects/mobile%2Fios%2Fshop/merge_requests/12": #"{"iid": 12, "title": "Checkout", "head_pipeline": {"id": 89, "sha": "abc"}}"#,
        "projects/mobile%2Fios%2Fshop/pipelines/89/jobs?scope%5B%5D=failed&per_page=100":
            #"[{"id": 4568, "name": "unitTests", "status": "failed"}, {"id": 4567, "name": "snapshotTest", "status": "failed"}]"#,
    ])

    @Test func findsTheFailedJobsOfTheBranchsMergeRequest() throws {
        let repo = try repo()
        let hosts = Destinations()
        let found = try #require(try CIDetector.detect(repository: repo.url) { host in
            hosts.append(host)
            return api
        })
        #expect(hosts.all == ["gitlab.example.com"])
        #expect(found.mergeRequest.iid == 12)
        #expect(found.pipeline.id == 89)
        #expect(found.failedJobs.map(\.id) == [4567, 4568])
        #expect(found.link(to: found.failedJobs[0]).jobURL == "https://gitlab.example.com/mobile/ios/shop/-/jobs/4567")
    }

    @Test func nothingWithoutAMergeRequestOrAFailure() throws {
        #expect(try CIDetector.detect(repository: try repo(branch: "main").url) { _ in
            FakeGitLab(["projects/mobile%2Fios%2Fshop/merge_requests?state=opened&source_branch=main": "[]"])
        } == nil)
        var passing = api
        passing.responses["projects/mobile%2Fios%2Fshop/pipelines/89/jobs?scope%5B%5D=failed&per_page=100"] = Data("[]".utf8)
        #expect(try CIDetector.detect(repository: try repo().url) { _ in passing } == nil)
    }
}

/// What a test's closures were called with, from any thread.
final class Destinations: @unchecked Sendable { // `values` is guarded by `lock`.
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

extension JSONDecoder {
    static var gitLab: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

extension CITestReport.Case {
    init(status: String, name: String, classname: String?) {
        self.init(status: status, name: name, classname: classname, systemOutput: nil, stackTrace: nil)
    }
}
