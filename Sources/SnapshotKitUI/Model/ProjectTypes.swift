import AppKit
import Foundation
import Observation
import SnapshotKitCore

// The values a project's model is made of: its sections, an operation, failures and where they came from.

/// How the library orders snapshots. Anything but name shows one flat list.
enum LibrarySort: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case recent = "Recently Changed"
    var id: String { rawValue }
}

/// What else SnapshotKit knows about one snapshot.
struct SnapshotStatus: Equatable {
    /// How it differs from the base branch, if it does.
    var change: SnapshotChangeKind?
    /// The failing test it is the reference of, from the last run.
    var failureID: String?
    var verdict: FlakeVerdict?
    /// Its test is gone (renamed or deleted).
    var orphaned = false
}

/// The second image in a snapshot's detail.
enum SnapshotComparison: Equatable {
    case version(SnapshotVersion)
    case variant(SnapshotFile)
}

/// What the Run view shows under its header.
enum RunPane: String, CaseIterable, Identifiable {
    case results = "Results"
    case output = "Output"
    var id: String { rawValue }
}

/// An item in the sidebar under the project, in the order it lists them. Each opens one of the
/// project's views, set up for what the item is about.
enum ProjectSection: Hashable, Identifiable {
    /// Snapshots changed in the working tree and not committed yet: review before committing.
    case workingCopy
    /// Every snapshot this checkout changes compared with the base branch, committed or not.
    case comparison
    /// The failing tests of the last run (local, remote or imported): investigate.
    case lastRun
    /// The failing tests of a CI job, by its id in GitLab: loaded, or offered to load.
    case ciJob(Int)
    /// Run and record. Goes once the run has a place of its own.
    case run
    /// Every snapshot in the project: browse, inspect, manage.
    case library
    /// Snapshots whose test no longer exists.
    case orphaned

    /// Its name for `--section`: "working-copy", "ci-job-4567".
    var id: String {
        switch self {
        case .workingCopy: "working-copy"
        case .comparison: "comparison"
        case .lastRun: "last-run"
        case .ciJob(let job): "ci-job-\(job)"
        case .run: "run"
        case .library: "library"
        case .orphaned: "orphaned"
        }
    }

    init?(id: String) {
        if id.hasPrefix("ci-job-"), let job = Int(id.dropFirst("ci-job-".count)) {
            self = .ciJob(job)
            return
        }
        guard let section = [Self.workingCopy, .comparison, .lastRun, .run, .library, .orphaned].first(where: { $0.id == id })
        else { return nil }
        self = section
    }

    /// The view the section opens.
    var content: SectionContent {
        switch self {
        case .workingCopy, .comparison: .changes
        case .lastRun, .ciJob: .failures
        case .run: .run
        case .library, .orphaned: .snapshots
        }
    }
}

/// The views behind the sidebar's sections.
enum SectionContent {
    case snapshots, changes, failures, run
}

enum RunOperation: Equatable {
    case run, rerecord, flakeCheck
    case remoteRun, remoteRecord, remoteFlakeCheck

    var label: String {
        switch self {
        case .run: "Running tests"
        case .rerecord: "Re-recording snapshots"
        case .flakeCheck: "Checking flakiness"
        case .remoteRun: "Running on remote"
        case .remoteRecord: "Re-recording on remote"
        case .remoteFlakeCheck: "Checking flakiness on remote"
        }
    }
}

/// A failing test with everything needed to investigate it.
struct FailureItem: Identifiable, Hashable {
    var suite: SuiteResult
    var test: TestCaseResult
    var images: [SnapshotFailureImages]
    var referencePaths: [String]
    var verdict: FlakeVerdict?
    var historyFlaky: FlakySignal?
    /// This test's results in recent recorded runs, oldest first.
    var timeline: [HistoryPoint] = []
    /// The devices it fails on every time while passing on the others, per the flakiness check.
    var failingDevices: [String]?
    /// `Bundle/Suite/test()`, as `-only-testing:`, the history and the verdicts name it (not by its display name).
    var id: String { suite.onlyTestingIdentifier(of: test) }
    /// What the flakiness check found: "Fails on iPhone SE" when only some devices fail it.
    var verdictLabel: String? { verdict?.label(failingDevices: failingDevices) }
    /// The test had no reference yet: one was just recorded, and the next run checks it.
    var isNewReference: Bool { test.failureMessages.contains(where: FailureAttachments.isNewReference) }
}

/// A project's folder is gone, or no longer in a git repository.
struct RepositoryGone: LocalizedError {
    var url: URL
    var errorDescription: String? {
        let name = url.path.abbreviatingWithTildeInPath
        return FileManager.default.fileExists(atPath: url.path)
            ? "\(name) isn’t in a git repository any more."
            : "There is no folder at \(name) any more. Was it moved or deleted?"
    }
}

/// Where the failures came from: a run, a result bundle or a CI job.
struct FailureSource: Equatable {
    var label: String
    var date: Date
    var host: String
    /// Local result bundle, when there is one (not for remote runs).
    var resultBundle: URL?
    /// The CI job they were loaded from.
    var jobURL: URL?
    /// More on where they came from: the merge request and commit of a CI job.
    var detail: String?
    /// What couldn't be fetched with them, such as images gone from a CI runner.
    var notes: [String] = []
    /// What would fetch it: a CI login to try, a command to run, the job to retry or load again.
    var fixes: [CIFix] = []
}

/// Where a set of failures comes from: the last run (local, remote or imported), or a CI job.
enum FailureOrigin: Hashable {
    case lastRun
    case ciJob(Int)

    var section: ProjectSection {
        switch self {
        case .lastRun: .lastRun
        case .ciJob(let job): .ciJob(job)
        }
    }
}

/// One source's failing tests, and how far you've got with them: each keeps its own selection,
/// diagnoses and flakiness verdicts.
struct FailureSet {
    var items: [FailureItem] = []
    var source: FailureSource?
    /// Its failing suites, which Re-record Failing Suites and Check Flakiness act on.
    var failingSuites: [SuiteResult] = []
    var flakeResults: [FlakeResult] = []
    /// What kind of difference each failure is (first repetition), computed in the background.
    var diagnoses: [String: DiffDiagnosis] = [:]
    var selectedID: String?
    /// Failures selected together with ⌘- or ⇧-click. `selectedID` stays the one in focus; a set
    /// that no longer contains it (the selection moved by keyboard) no longer counts.
    var selection: Set<String> = []
    /// A CI job's job and merge request, which the sidebar names and groups it by.
    var job: GitLabJob?
    var mergeRequest: GitLabMergeRequest?
    /// A CI job's tests re-recorded here since it loaded (those the verification passed, when there was one):
    /// fixed in the working tree, though the job failed them and lists them still.
    var reRecorded: Set<String> = []
}

/// Where a notice can take you next.
enum NoticeAction: Equatable {
    case reviewChanges
    case showFailures(FailureOrigin)

    var title: String {
        switch self {
        case .reviewChanges: "Review Changes"
        case .showFailures: "Show Failures"
        }
    }

    /// Where it leads: re-recorded snapshots are uncommitted changes.
    var section: ProjectSection {
        switch self {
        case .reviewChanges: .workingCopy
        case .showFailures(let origin): origin.section
        }
    }
}
