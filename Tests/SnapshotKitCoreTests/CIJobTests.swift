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

    /// A diff tool may quote with single quotes, and a reference may be outside `__Snapshots__`: then the order tells,
    /// reference first, as swift-snapshot-testing passes them.
    @Test func readsSingleQuotesAndTheOrder() {
        let quoted = SnapshotMismatch.parse("ksdiff '/ci/tmp/Card Tests/card.1.png' '/ci/app/__Snapshots__/Card Tests/card.1.png'")
        #expect(quoted.map(\.reference) == ["/ci/app/__Snapshots__/Card Tests/card.1.png"])
        #expect(quoted.map(\.actual) == ["/ci/tmp/Card Tests/card.1.png"])
        let custom = SnapshotMismatch.parse(#"compare "/ci/app/References/card.png" "/ci/tmp/card.png""#)
        #expect(custom.map(\.reference) == ["/ci/app/References/card.png"] && custom.map(\.actual) == ["/ci/tmp/card.png"])
        #expect(SnapshotMismatch.parse(#"compare "/ci/a.png" "/ci/a.png""#).isEmpty)
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
                + "copied. The images are in /Users/ci-runner/: set CI login under Run to `ci-runner`.")
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

/// The forms swift-snapshot-testing's messages take, and those JUnit writers turn them into.
extension SnapshotMismatchTests {
    static let pair = (reference: "/ci/app/__Snapshots__/CardTests/card.1.png", actual: "/ci/tmp/CardTests/card.1.png")

    /// A writer that keeps the message as a string literal escapes its quotes, and maybe its line breaks.
    @Test(arguments: [
        #"Snapshot does not match reference.\n\nksdiff \"/ci/app/__Snapshots__/CardTests/card.1.png\" \"/ci/tmp/CardTests/card.1.png\"\n\nThe percentage of pixels that match 0.5 is less than required 1.0"#,
        "Snapshot does not match reference.\n\nksdiff \\\"/ci/app/__Snapshots__/CardTests/card.1.png\\\" \\\"/ci/tmp/CardTests/card.1.png\\\"\n\nThe percentage of pixels that match 0.5 is less than required 1.0",
        #"Snapshot does not match reference.\n\n@\u{2212}\n\"file:///ci/app/__Snapshots__/CardTests/card.1.png\"\n@+\n\"file:///ci/tmp/CardTests/card.1.png\"\n\nThe percentage of pixels that match 0.5 is less than required 1.0"#,
        #"Snapshot does not match reference.\n\n@−\n\"file:///ci/app/__Snapshots__/CardTests/card.1.png\"\n@+\n\"file:///ci/tmp/CardTests/card.1.png\"\n\nThe percentage of pixels that match 0.5 is less than required 1.0"#,
        // Escaped twice: a literal of a literal.
        #"Snapshot does not match reference.\\n\\n@−\\n\\\"file:///ci/app/__Snapshots__/CardTests/card.1.png\\\"\\n@+\\n\\\"file:///ci/tmp/CardTests/card.1.png\\\"\\n\\nThe percentage of pixels that match 0.5 is less than required 1.0"#,
        // XML entities a writer left in.
        "Snapshot does not match reference.&#10;&#10;@−&#10;&quot;file:///ci/app/__Snapshots__/CardTests/card.1.png&quot;&#10;@+&#10;&quot;file:///ci/tmp/CardTests/card.1.png&quot;&#10;&#10;The percentage of pixels that match 0.5 is less than required 1.0",
    ])
    func readsAnEscapedMessage(_ message: String) {
        let mismatches = SnapshotMismatch.parse(message)
        #expect(mismatches == [SnapshotMismatch(reference: Self.pair.reference, actual: Self.pair.actual, pixels: .init(actual: 0.5, required: 1))])
        // Shown unescaped: the paths read as paths.
        #expect(SnapshotMismatch.readable(message).contains("/ci/tmp/CardTests/card.1.png\""))
        #expect(!SnapshotMismatch.readable(message).contains("\\\""))
        #expect(SnapshotMismatch.isSnapshotFailure(message))
    }

    @Test(arguments: [
        // A plain hyphen, and paths instead of URLs.
        "@-\n\"/ci/app/__Snapshots__/CardTests/card.1.png\"\n@+\n\"/ci/tmp/CardTests/card.1.png\"",
        "@−\r\n\"file:///ci/app/__Snapshots__/CardTests/card.1.png\"\r\n@+\r\n\"file:///ci/tmp/CardTests/card.1.png\"",
        // A diff tool given file URLs, unquoted; another quoted, with its own words around them.
        "compare file:///ci/app/__Snapshots__/CardTests/card.1.png file:///ci/tmp/CardTests/card.1.png diff.png",
        "open -a Kaleidoscope \"/ci/tmp/CardTests/card.1.png\" \"/ci/app/__Snapshots__/CardTests/card.1.png\"",
    ])
    func readsOtherForms(_ message: String) {
        #expect(SnapshotMismatch.parse(message).map(\.reference) == [Self.pair.reference])
        #expect(SnapshotMismatch.parse(message).map(\.actual) == [Self.pair.actual])
    }

    @Test func decodesTheURLsOfPathsWithSpaces() {
        let message = "@−\n\"file:///Users/ci/My%20App/__Snapshots__/S/a.1.png\"\n@+\n\"file:///tmp/My%20App/S/a.1.png\""
        #expect(SnapshotMismatch.parse(message).first?.reference == "/Users/ci/My App/__Snapshots__/S/a.1.png")
        #expect(SnapshotMismatch.parse(message).first?.actual == "/tmp/My App/S/a.1.png")
    }

    /// No reference: the test recorded the image it took as one, on the runner, and failed.
    @Test func readsARecordedSnapshot() {
        for opening in ["No reference was found on disk.", "Record mode is on."] {
            let message = """
            failed - \(opening) Automatically recorded snapshot: …

            open "file:///ci/app/__Snapshots__/CardTests/card.1.png"

            Re-run "card()" to assert against the newly-recorded snapshot.
            """
            let mismatch = SnapshotMismatch.parse(message)
            #expect(mismatch == [SnapshotMismatch(actual: Self.pair.reference, recorded: true)])
            #expect(mismatch.first?.namesImages == true)
        }
    }

    @Test func tellsTextSnapshotsFromImages() {
        let text = SnapshotMismatch.parse("@−\n\"file:///r/__Snapshots__/S/a.1.txt\"\n@+\n\"file:///t/S/a.1.txt\"\n\n@@ −1,1 +1,1 @@\n−a\n+b")
        #expect(text.count == 1 && text[0].namesImages && !text[0].isImage)
        #expect(SnapshotMismatch.parse(Self.message("testPayButton"))[0].isImage)
    }

    /// Some messages say a snapshot didn't match without naming its images: that is still a snapshot failure.
    @Test func knowsASnapshotFailureWithoutItsImages() {
        #expect(SnapshotMismatch.isSnapshotFailure("Snapshot does not match reference."))
        #expect(SnapshotMismatch.isSnapshotFailure(#"Snapshot \"dark\" does not match reference."#))
        #expect(SnapshotMismatch.isSnapshotFailure("The percentage of pixels that match 0.5 is less than required 1.0"))
        #expect(SnapshotMismatch.parse("Snapshot does not match reference.").isEmpty)
        #expect(!SnapshotMismatch.isSnapshotFailure(#"XCTAssertEqual failed: ("\"12\"") is not equal to ("\"13\"")"#))
    }

    /// Only a message that reads as a snapshot failure once unescaped is shown unescaped.
    @Test func leavesOtherMessagesAsTheyAre() {
        let other = #"XCTAssertEqual failed: ("\"12\"") is not equal to ("\"13\"")\n"#
        #expect(SnapshotMismatch.readable(other) == other)
        #expect(SnapshotMismatch.readable(Self.message("testPayButton")) == Self.message("testPayButton"))
        #expect(SnapshotMismatch.unescaped(#"a\u{2212}b A &amp;&lt;&#x41; \q &nope;"#) == "a−b A &<A \\q &nope;")
    }
}

extension CIImporterTests {
    /// The report with one test case's message replaced.
    func report(_ api: FakeGitLab, replacing name: String, with message: String) throws -> FakeGitLab {
        let path = "projects/mobile%2Fios%2Fshop/pipelines/89/test_report"
        let data = try #require(api.responses[path])
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var suites = try #require(json["test_suites"] as? [[String: Any]])
        var cases = try #require(suites[0]["test_cases"] as? [[String: Any]])
        let i = try #require(cases.firstIndex { $0["name"] as? String == name })
        cases[i]["system_output"] = message
        suites[0]["test_cases"] = cases
        json["test_suites"] = suites
        var changed = api
        changed.responses[path] = try JSONSerialization.data(withJSONObject: json)
        return changed
    }

    @Test func anEscapedMessageStillFetchesItsImages() throws {
        let (repo, api) = try setUp()
        let original = SnapshotMismatchTests.message("testPayButton").replacingOccurrences(of: "/Users/ci-runner", with: runner.path)
        let escaped = original.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        let result = try importer(repo, try report(api, replacing: "testPayButton", with: escaped)).load(link, into: directory)
        let image = try #require(result.images.first { $0.testIdentifier == "CardTests/testPayButton()" })
        #expect(try image.failure.map { try String(contentsOf: $0, encoding: .utf8) } == "actual pay")
        #expect(image.reference != nil)
        // Shown as swift-snapshot-testing wrote it.
        #expect(result.summary.suites.flatMap(\.tests).first?.failureMessages == [original])
    }

    /// A snapshot failure whose message names no images says so, for the job and the test.
    @Test func aMismatchWithoutPathsIsNoted() throws {
        let (repo, api) = try setUp()
        let result = try importer(repo, try report(api, replacing: "testPayButton", with: "Snapshot does not match reference.")).load(link, into: directory)
        #expect(!result.images.contains { $0.testIdentifier == "CardTests/testPayButton()" })
        #expect(result.notes.contains("The failure message of testPayButton() says a snapshot didn’t match, but names no image files, so there is "
                                      + "nothing to fetch. The test report may cut long messages short."))
    }

    /// Each image not shown says why: here, gone from the runner. And the fix: a new run of the job.
    @Test func aMissingImageSaysWhy() throws {
        let (repo, api) = try setUp()
        let result = try importer(repo, api).load(link, into: directory)
        let summary = try #require(result.images.first { $0.testIdentifier == "CheckoutTests/testSummary()" })
        #expect(summary.failureMissing?.hasPrefix("No longer on ci-mac-1: it removes the images the tests took when its next job starts.") == true)
        #expect(summary.referenceMissing == nil)
        #expect(result.images.first { $0.testIdentifier == "CardTests/testPayButton()" }?.failureMissing == nil)
        #expect(result.fixes == [.retryJob])
    }

    /// The runner removes the images when its next job starts: loading the job again keeps those copied before.
    @Test func loadingAgainKeepsTheImagesCopiedBefore() throws {
        let (repo, api) = try setUp()
        _ = try importer(repo, api).load(link, into: directory)
        try FileManager.default.removeItem(at: runner.appendingPathComponent("\(tmp)/CardTests/testPayButton.1.png"))
        let again = try importer(repo, api).load(link, into: directory)
        let pay = try #require(again.images.first { $0.testIdentifier == "CardTests/testPayButton()" })
        #expect(try pay.failure.map { try String(contentsOf: $0, encoding: .utf8) } == "actual pay")
        #expect(again.notes == ["1 of the 2 images the tests took is no longer on ci-mac-1: it removes them when its next job starts. "
                                + "Run the job again to see it."])
    }

    /// No reference: the test recorded one on the runner, which is the image to show.
    @Test func aRecordedSnapshotIsTheImageTaken() throws {
        let (repo, api) = try setUp()
        let recorded = runner.appendingPathComponent("builds/x1Y2z3/0/mobile/ios/shop/Example/ShopSnapshotTests/__Snapshots__/CardTests/testNew.1.png")
        try FileManager.default.createDirectory(at: recorded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("recorded".utf8).write(to: recorded)
        let message = "No reference was found on disk. Automatically recorded snapshot: …\n\nopen \"file://\(recorded.path)\"\n\n"
            + "Re-run \"testNew\" to assert against the newly-recorded snapshot."
        let result = try importer(repo, try report(api, replacing: "testPayButton", with: message)).load(link, into: directory)
        let image = try #require(result.images.first { $0.testIdentifier == "CardTests/testPayButton()" })
        #expect(try image.failure.map { try String(contentsOf: $0, encoding: .utf8) } == "recorded")
        #expect(image.reference == nil)
        #expect(image.referenceMissing?.hasPrefix("No reference was committed") == true)
        #expect(image.referencePath == "Example/ShopSnapshotTests/__Snapshots__/CardTests/testNew.1.png")
    }

    /// The runner's answer to which images it has: there, behind a folder the login can't open, or gone.
    @Test func readsWhichImagesTheRunnerHas() throws {
        let files = CIImporter.RunnerFiles(output: "user\tbuilder\nok\t/a.png\ndenied\t/b.png\nok\t/elsewhere.png\n", asked: ["/a.png", "/b.png", "/c.png"])
        #expect(files.user == "builder")
        #expect(files.present == ["/a.png"])
        #expect(files.unreadable == ["/b.png"])
        #expect(files.gone == ["/c.png"])

        let there = runner.appendingPathComponent("there.png")
        try FileManager.default.createDirectory(at: runner, withIntermediateDirectories: true)
        try Data().write(to: there)
        let gone = runner.appendingPathComponent("gone/it's.png").path
        let output = try LocalDirectoryTransport().run(CIImporter.RunnerFiles.script([there.path, gone]))
        let local = CIImporter.RunnerFiles(output: output, asked: [there.path, gone])
        #expect(local.present == [there.path])
        #expect(local.gone == [gone])
        #expect(local.user?.isEmpty == false)
    }

    @Test func aJobGitLabDoesntHaveSaysSo() throws {
        let (repo, _) = try setUp()
        #expect(throws: GitLabError.jobNotFound(id: 4567, project: "mobile/ios/shop", host: "gitlab.example.com")) {
            try importer(repo, FakeGitLab([:])).load(link, into: directory)
        }
    }

    /// A job that failed without a failing test failed elsewhere: building, a script step.
    @Test func aJobThatFailedOutsideTheTestsSaysSo() throws {
        let (repo, api) = try setUp()
        var bare = api
        bare.responses["projects/mobile%2Fios%2Fshop/pipelines/89/test_report"] = Data(#"{"test_suites": []}"#.utf8)
        bare.responses["projects/mobile%2Fios%2Fshop/jobs/4567/trace"] = Data("error: build failed\n".utf8)
        let result = try importer(repo, bare).load(link, into: directory)
        #expect(result.summary.suites.isEmpty)
        #expect(result.notes == ["snapshotTest failed, but neither its test report nor its log names a failing test: it failed outside the tests "
                                 + "(building, a script step, a timeout). Its log on GitLab says why."])
    }

    /// The report names its suites after the jobs; one that has none for this job says which it has.
    @Test func aReportWithoutTheJobsSuiteNamesThoseItHas() throws {
        let (repo, api) = try setUp()
        var other = api
        other.responses["projects/mobile%2Fios%2Fshop/pipelines/89/test_report"] = Data(#"{"test_suites": [{"name": "unitTests", "test_cases": []}]}"#.utf8)
        let result = try importer(repo, other).load(link, into: directory)
        #expect(result.notes == ["The pipeline’s test report has no suite for snapshotTest, only for “unitTests”, so its failure messages, "
                                 + "references and images are unknown."])
        #expect(CIImporter.suite("snapshotTest", isOf: "snapshotTest 2/3"))
        #expect(!CIImporter.suite("snapshotTest", isOf: "snapshotTest-iPad"))
    }

    /// A refused login suggests the user whose home the images are in, also when a login is set, and offers it.
    @Test func aRefusedLoginSuggestsTheImagesOwner() {
        let paths = ["/Users/ci-runner/Library/Developer/CoreSimulator/Devices/X/data/tmp/a.png"]
        func diagnosis(_ output: String, login: String?) -> CIImporter.SSHDiagnosis {
            var importer = CIImporter(api: FakeGitLab([:]), repository: URL(fileURLWithPath: "/"))
            importer.login = login
            return importer.sshDiagnosis(for: RemoteError.commandFailed(host: "x", script: "", status: 255, output: output),
                                         destination: CIImporter.destination(login: login, runner: "ci-mac-1"), runner: "ci-mac-1", paths: paths)
        }
        let denied = "Permission denied (publickey,password,keyboard-interactive)."
        #expect(diagnosis(denied, login: nil).fixes == [.useLogin("ci-runner"), .runCommand("ssh ci-runner@ci-mac-1 true")])
        let builder = diagnosis(denied, login: "builder")
        #expect(builder.note.contains("so the login is likely `ci-runner`: set CI login under Run to it."))
        #expect(builder.fixes == [.useLogin("ci-runner"), .runCommand("ssh ci-runner@ci-mac-1 true")])
        #expect(builder.reason == "builder@ci-mac-1 refused the SSH login. The images are ci-runner’s: log in as `ci-runner` (CI login under Run).")
        #expect(diagnosis(denied, login: "builder@ci-mac-1.example.com").fixes.first == .useLogin("ci-runner@ci-mac-1.example.com"))
        // The owner's own login refused: the key, not the user.
        let owner = diagnosis(denied, login: "ci-runner")
        #expect(owner.fixes == [.runCommand("ssh ci-runner@ci-mac-1 true"), .loadAgain])
        #expect(owner.note.contains("ssh-agent"))
        // Logged in, but not allowed to read the owner's files.
        let unreadable = diagnosis(#"rsync: [sender] send_files failed to open "/Users/ci-runner/a.png": Permission denied (13)"#, login: "builder")
        #expect(unreadable.note == "builder@ci-mac-1 can’t read the images the tests took: they are in /Users/ci-runner/. Set CI login under Run to `ci-runner`.")
        #expect(unreadable.fixes == [.useLogin("ci-runner")])
    }

    @Test func otherSSHProblemsSayWhatToCheck() throws {
        let importer = CIImporter(api: FakeGitLab([:]), repository: URL(fileURLWithPath: "/"))
        func diagnosis(_ error: Error, runner: String = "ci-mac-1") -> CIImporter.SSHDiagnosis {
            importer.sshDiagnosis(for: error, destination: runner, runner: runner, paths: [])
        }
        let unknown = diagnosis(RemoteError.commandFailed(host: "ci-mac-1", script: "", status: 255,
                                                          output: "ssh: Could not resolve hostname ci-mac-1: nodename nor servname provided, or not known"))
        #expect(unknown.note.contains("set CI login under Run to `user@address`, or give it a `Host ci-mac-1` entry"))
        let named = diagnosis(RemoteError.invalidHost("Mac mini (M2)"), runner: "Mac mini (M2)")
        #expect(named.note.hasPrefix("GitLab names the runner “Mac mini (M2)”, which isn’t a host name"))
        let trust = diagnosis(RemoteError.commandFailed(host: "ci-mac-1", script: "", status: 255, output: "Host key verification failed."))
        #expect(trust.fixes == [.runCommand("ssh ci-mac-1 true"), .loadAgain])
        let timeout = diagnosis(RemoteError.commandFailed(host: "ci-mac-1", script: "", status: 255,
                                                          output: "ssh: connect to host ci-mac-1 port 22: Operation timed out"))
        #expect(timeout.note == "Couldn’t copy the images the tests took from ci-mac-1: ci-mac-1 didn’t answer over SSH (ssh: connect to host "
                + "ci-mac-1 port 22: Operation timed out). Check that you’re on its network (or VPN) and that Remote Login is on there, then load the job again.")
        #expect(CIImporter.homeOwner(of: "/home/gitlab-runner/builds/a.png") == "gitlab-runner")
        #expect(CIImporter.homeOwner(of: "/Users/Shared/a.png") == nil)
        #expect(CIImporter.homeOwner(of: "/private/var/folders/a.png") == nil)
    }

    /// Each SSH problem leaves every image it kept from being copied a reason.
    @Test func anSSHProblemIsEachImagesReason() throws {
        let (repo, api) = try setUp()
        var importer = importer(repo, api)
        importer.transport = { _ in throw RemoteError.invalidHost("ci-mac-1") }
        let result = try importer.load(link, into: directory)
        #expect(result.images.allSatisfy { $0.failure == nil && $0.failureMissing?.contains("isn’t a host name") == true })
    }
}

@Suite(.isolated) struct GitLabErrorTests {
    @Test func tellsWhatWentWrong() {
        func classify(_ output: String, via: String = "glab") -> GitLabError {
            GitLabError.classify(path: "projects/x/jobs/1", output: output, host: "gitlab.example.com", via: via)
        }
        #expect(classify("glab: 401 Unauthorized (HTTP 401)") == .unauthorized(host: "gitlab.example.com", via: "glab", detail: "glab: 401 Unauthorized (HTTP 401)"))
        #expect(classify("none of the git remotes configured for this repository points to a known GitLab host. Please use `glab auth login`")
                == .unauthorized(host: "gitlab.example.com", via: "glab",
                                 detail: "none of the git remotes configured for this repository points to a known GitLab host. Please use `glab auth login`"))
        #expect(classify(#"{"message":"403 Forbidden"}"#) == .forbidden(host: "gitlab.example.com", path: "projects/x/jobs/1", via: "glab"))
        #expect(classify("glab: 404 Not Found (HTTP 404)") == .notFound(path: "projects/x/jobs/1"))
        #expect(classify("curl: (6) Could not resolve host: gitlab.example.com", via: "GITLAB_TOKEN")
                == .unreachable(host: "gitlab.example.com", detail: "curl: (6) Could not resolve host: gitlab.example.com"))
        #expect(classify("500 Internal Server Error\nupstream 4040ms") == .request(path: "projects/x/jobs/1", output: "upstream 4040ms"))
        #expect(GitLabError.request(path: "p", output: "404 Not Found").isNotFound)
        #expect(!GitLabError.request(path: "p", output: "took 4045 ms").isNotFound)
    }

    /// Each says what to do, naming the token's variable, never its value.
    @Test func saysWhatToDo() {
        #expect(GitLabError.glabMissing(host: "gitlab.example.com").localizedDescription.contains("`glab auth login --hostname gitlab.example.com`"))
        let rejected = GitLabError.unauthorized(host: "gitlab.example.com", via: "GITLAB_PRIVATE_TOKEN", detail: "401 Unauthorized").localizedDescription
        #expect(rejected.hasPrefix("GitLab on gitlab.example.com rejected GITLAB_PRIVATE_TOKEN (401 Unauthorized)"))
        let api = DefaultGitLabAPI(host: "gitlab.example.com", environment: ["GITLAB_PRIVATE_TOKEN": "glpat-secret"])
        #expect((api.token as? TokenAPI)?.tokenVariable == "GITLAB_PRIVATE_TOKEN")
        #expect(DefaultGitLabAPI(host: "h", environment: ["GITLAB_TOKEN": "", "GITLAB_PRIVATE_TOKEN": "b"]).token != nil)
        #expect(DefaultGitLabAPI(host: "h", environment: ["GITLAB_TOKEN": ""]).token == nil)
    }

    /// An answer that isn't JSON, as from a sign-in page in front of GitLab, says how it starts.
    @Test func anAnswerThatIsntJSONSaysHowItStarts() {
        let api = FakeGitLab(["projects/x/jobs/1": "<!DOCTYPE html>\n<html><title>Sign in</title>"])
        #expect(throws: GitLabError.unreadable(path: "projects/x/jobs/1", start: "<!DOCTYPE html>")) {
            try api.get("projects/x/jobs/1", as: GitLabJob.self)
        }
    }

    /// A JUnit writer may split the message between system output and stack trace: the snapshot failure is the message.
    @Test func theMessageIsTheSnapshotFailure() {
        let failure = "Snapshot does not match reference."
        let split = CITestReport.Case(status: "failed", name: "testCard()", classname: "CardTests",
                                      systemOutput: "Rendering CardView", stackTrace: failure)
        #expect(split.message == failure)
        let other = CITestReport.Case(status: "failed", name: "testCard()", classname: "CardTests", systemOutput: "", stackTrace: "XCTAssertTrue failed")
        #expect(other.message == "XCTAssertTrue failed")
    }

    /// Without glab and without a token there is no way in, and the error says both ways.
    @Test func withoutGlabOrATokenSaysHowToSignIn() throws {
        struct MissingGlab: GitLabAPI {
            func get(_ path: String) throws -> Data {
                throw CommandError(command: ["glab"], result: CommandResult(status: 127, stdout: "", stderr: "env: glab: No such file or directory"))
            }
        }
        var api = DefaultGitLabAPI(host: "gitlab.example.com", environment: [:])
        api.glab = MissingGlab()
        #expect(throws: GitLabError.glabMissing(host: "gitlab.example.com")) { try api.get("projects/x/jobs/1") }
    }
}

@Suite(.isolated) struct MissingImagesTests {
    func explain(_ messages: [String], _ images: [SnapshotFailureImages] = []) -> MissingImages {
        MissingImages.explain(messages: messages, images: images)
    }

    /// What was tried comes first: the image's own reasons.
    @Test func saysWhyEachSideIsMissing() {
        let image = SnapshotFailureImages(testIdentifier: "S/a()", repetition: 1, index: 0,
                                          referenceMissing: "isn’t in the job’s commit 3f1c2a9b.", failureMissing: "No longer on ci-mac-1.")
        #expect(explain(["Snapshot does not match reference."], [image])
                == MissingImages(title: "Images Not Available", reason: "Reference: isn’t in the job’s commit 3f1c2a9b.\nActual: No longer on ci-mac-1."))
    }

    /// A snapshot failure whose paths didn't come through is still one.
    @Test func aSnapshotFailureIsNeverCalledSomethingElse() {
        #expect(explain(["Snapshot does not match reference."]).title == "Images Not Named")
        #expect(explain([#"Snapshot does not match reference.\n\nksdiff \"/r/__Snapshots__/a.png\" \"/t/a.png\""#]).title == "Images Not Found")
        #expect(explain(["@−\n\"file:///r/__Snapshots__/S/a.1.txt\"\n@+\n\"file:///t/S/a.1.txt\""]).title == "Text Snapshot")
        #expect(explain([]).title == "No Failure Message")
        #expect(explain(["XCTAssertEqual failed: (\"12\") is not equal to (\"13\")"]).title == "Not a Snapshot Failure")
    }
}
