import Foundation
import SnapshotKitCore
import Testing
@testable import SnapshotKitUI

extension AppUITests {
    /// Loading failed CI jobs, each into its own sidebar item, with GitLab and the runner replaced by the model's seams.
    @MainActor
    @Suite(.serialized)
    struct CIJobModelTests {
        init() {
            AppFixtures.resetDefaults()
        }

        let link = GitLabLink(host: "gitlab.example.com", projectPath: "mobile/ios/shop", jobID: 4567)
        let job = GitLabJob(id: 4567, name: "snapshotTest", status: "failed", ref: "feature", commit: .init(id: "3f1c2a9b8d7e6f50"),
                            pipeline: GitLabPipeline(id: 89), runner: .init(description: "ci-mac-1"), finishedAt: "2026-10-26T08:22:02.120Z")
        let message = "Snapshot does not match reference.\n\nThe percentage of pixels that match 0.9935 is less than required 1.0"

        func model() -> (ProjectModel, URL) {
            let repo = AppFixtures.temporaryDirectory("ci")
            return (ProjectModel(project: Project(path: repo.path), store: AppFixtures.store(), autoload: false), repo)
        }

        func loaded(notes: [String] = []) -> CIImport {
            let test = TestCaseResult(name: "card()", identifier: "CardTests/card()", outcome: .failed, failureMessages: [message], repetitions: [.failed])
            return CIImport(link: link, job: job, mergeRequest: GitLabMergeRequest(iid: 12, title: "Checkout"),
                            summary: TestRunSummary(suites: [SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [test], failureFiles: [])]),
                            notes: notes, passed: 3)
        }

        @Test func loadingAJobShowsItsFailuresAsARunsWithItsNotes() async throws {
            let (model, repo) = model()
            let calls = Calls()
            let loaded = loaded(notes: ["The images the tests took are no longer on ci-mac-1: it removes them when its next job starts."])
            model.importCI = { link, login, _, _ in
                calls.append("\(link.jobID ?? 0) as \(login ?? "default")")
                return loaded
            }
            model.setCILogin("  ci-runner ")
            await model.loadCIJob(url: "https://gitlab.example.com/mobile/ios/shop/-/jobs/4567").value

            #expect(calls.all == ["4567 as ci-runner"])
            #expect(model.failureSets[.lastRun] == nil)          // the job has its own failures
            #expect(model.ciJobGroups.map(\.title) == ["CI · !12"])
            model.section = .ciJob(4567)
            #expect(model.failures.map(\.id) == ["AppTests/CardTests/card()"])
            #expect(model.failingSuites.map(\.identifier) == ["AppTests/CardTests"])     // to re-record here
            let source = try #require(model.failureSource)
            #expect(source.label == "snapshotTest #4567")
            #expect(source.host == "ci-mac-1")
            #expect(source.detail == "!12 · 3f1c2a9b")
            #expect(source.jobURL == URL(string: "https://gitlab.example.com/mobile/ios/shop/-/jobs/4567"))
            #expect(source.notes == loaded.notes)
            #expect(source.date == job.finished)
            #expect(model.lastMessage == "Loaded 1 failing test from snapshotTest #4567. Not everything could be fetched; the job’s failures say what.")
            // Recorded, without a commit: another machine's results say nothing about flakiness here.
            let record = try #require(RunHistory(repository: repo).load().last)
            #expect(record.kind == .imported && record.host == "ci-mac-1" && record.commit == nil && record.failed == 1 && record.passed == 3)
        }

        @Test func offersTheBranchsFailedJobsUntilOneIsLoaded() async throws {
            let (model, _) = model()
            let other = GitLabJob(id: 4568, name: "unitTests", status: "failed")
            let detection = CIDetection(project: GitLabLink(host: link.host, projectPath: link.projectPath), branch: "feature",
                                        mergeRequest: GitLabMergeRequest(iid: 12, title: "Checkout"), pipeline: GitLabPipeline(id: 89),
                                        failedJobs: [job, other])
            model.detectCI = { _ in detection }
            await model.checkCI().value
            #expect(model.offeredCIJobs.map(\.id) == [4567, 4568])

            let calls = Calls()
            let loaded = loaded()
            model.importCI = { link, _, _, _ in
                calls.append(link.jobURL ?? "")
                return loaded
            }
            await model.loadCIJob(job).value
            #expect(calls.all == ["https://gitlab.example.com/mobile/ios/shop/-/jobs/4567"])
            #expect(model.offeredCIJobs.map(\.id) == [4568])
            // Both stay in the merge request's group: one loaded, one to load.
            #expect(model.ciJobGroups.map { $0.jobs.map(\.id) } == [[4567, 4568]])
            #expect(model.count(of: .ciJob(4567)) == 1 && model.count(of: .ciJob(4568)) == nil)
        }

        /// Opening a job's item loads it, beside the last run's failures, which stay as they were.
        @Test func openingAJobLoadsItBesideTheLastRun() async throws {
            let (model, _) = model()
            let detection = CIDetection(project: GitLabLink(host: link.host, projectPath: link.projectPath), branch: "feature",
                                        mergeRequest: GitLabMergeRequest(iid: 12, title: "Checkout"), pipeline: GitLabPipeline(id: 89),
                                        failedJobs: [job])
            model.detectCI = { _ in detection }
            await model.checkCI().value
            let loaded = loaded()
            model.importCI = { _, _, _, _ in loaded }
            var f = ProjectFixture()
            f.failures = AppFixtures.failures(in: AppFixtures.temporaryDirectory("last-run"))
            f.failureSource = FailureSource(label: "Local run", date: Date(), host: "local")
            f.section = .lastRun
            f.ciDetection = detection
            model.apply(f)
            let lastRun = model.failures.map(\.id)

            model.section = .ciJob(job.id)
            #expect(model.loadingCIJobs == [job.id])
            #expect(model.countLabel(of: .ciJob(job.id)) == "loading")
            try await waitUntil(model.loadingCIJobs.isEmpty, "the job didn't load")
            #expect(model.failures.map(\.id) == ["AppTests/CardTests/card()"])
            #expect(model.title(of: .ciJob(job.id)) == "CI Job snapshotTest #4567")

            model.section = .lastRun
            #expect(model.failures.map(\.id) == lastRun)
            #expect(model.dockBadge == "\(lastRun.count)")      // the last run's, whatever CI says
        }

        /// A job that couldn't load says why in its item, and loads again only when asked.
        @Test func aJobThatCouldNotLoadWaitsForTryAgain() async throws {
            let (model, _) = model()
            let detection = CIDetection(project: GitLabLink(host: link.host, projectPath: link.projectPath), branch: "feature",
                                        mergeRequest: GitLabMergeRequest(iid: 12, title: "Checkout"), pipeline: GitLabPipeline(id: 89),
                                        failedJobs: [job])
            model.detectCI = { _ in detection }
            await model.checkCI().value
            let calls = Calls()
            model.importCI = { _, _, _, _ in
                calls.append("load")
                throw GitLabError.request(path: "jobs/4567", output: "500")
            }
            model.section = .ciJob(job.id)
            try await waitUntil(model.loadingCIJobs.isEmpty, "the load didn't end")
            #expect(model.ciLoadErrors[job.id] != nil)
            model.section = .library
            model.section = .ciJob(job.id)              // back again: no second attempt by itself
            #expect(calls.all == ["load"])
            await model.loadCIJob(job).value          // Try Again
            #expect(calls.all == ["load", "load"])
        }

        /// No GitLab, no merge request, no access: no banner, and no error either.
        @Test func aFailedCheckOffersNothing() async {
            let (model, _) = model()
            model.detectCI = { _ in throw GitLabError.noAccess(host: "gitlab.example.com", detail: "glab isn’t installed") }
            await model.checkCI().value
            #expect(model.offeredCIJobs.isEmpty)
            #expect(model.lastMessage == nil)
        }

        @Test func whatCantBeLoadedSaysWhy() async {
            let (model, _) = model()
            model.importCI = { _, _, _, _ in Issue.record("nothing to load"); throw CancellationError() }
            await model.loadCIJob(url: "https://gitlab.example.com/mobile/ios/shop/-/pipelines/89").value
            #expect(model.lastMessage == "Couldn’t load the CI job: “https://gitlab.example.com/mobile/ios/shop/-/pipelines/89” isn’t a GitLab "
                    + "job’s URL (https://gitlab.example.com/group/project/-/jobs/123).")
            #expect(model.lastMessageIsError)

            model.importCI = { _, _, _, _ in throw GitLabError.request(path: "projects/mobile%2Fios%2Fshop/jobs/4567", output: "404 Not Found") }
            await model.loadCIJob(url: "https://gitlab.example.com/mobile/ios/shop/-/jobs/4567").value
            #expect(model.lastMessage == "Couldn’t load the CI job: GitLab answered `projects/mobile%2Fios%2Fshop/jobs/4567` with: 404 Not Found")
            #expect(model.failureSets.isEmpty)
            #expect(model.loadingCIJobs.isEmpty)
        }

        func waitUntil(_ condition: @autoclosure () -> Bool, _ comment: Comment,
                       sourceLocation: SourceLocation = #_sourceLocation) async throws {
            for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
            try #require(condition(), comment, sourceLocation: sourceLocation)
        }

        @Test func theLoginIsKeptTrimmedAndEmptyIsNone() {
            let (model, _) = model()
            model.setCILogin("  builder@ci-mac-1.example.com ")
            #expect(model.settings.ciLogin == "builder@ci-mac-1.example.com")
            model.setCILogin(" ")
            #expect(model.settings.ciLogin == nil)
        }
    }
}

/// What a seam was called with, from any thread.
final class Calls: @unchecked Sendable { // `values` is guarded by `lock`.
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}
