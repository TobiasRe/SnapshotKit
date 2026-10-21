import AppKit
import Foundation
import Observation
import SnapshotKitCore

/// Which snapshots the library shows.
enum LibraryScope: String, CaseIterable, Identifiable {
    case all = "All"
    case changed = "Changed"
    case failing = "Failing"
    case uncommitted = "Uncommitted"
    /// Snapshots whose test no longer exists.
    case orphaned = "Orphaned"
    var id: String { rawValue }
}

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

/// What the Run tab shows under its header.
enum RunPane: String, CaseIterable, Identifiable {
    case results = "Results"
    case output = "Output"
    var id: String { rawValue }
}

enum ProjectTab: String, CaseIterable, Identifiable {
    /// Every snapshot in the project: browse, inspect, manage.
    case snapshots = "Snapshots"
    /// Snapshots that differ from the base branch: review.
    case changes = "Changes"
    /// Snapshots whose tests failed in the last run: investigate.
    case failures = "Failures"
    /// Run and record.
    case run = "Run"
    var id: String { rawValue }
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

/// Where the failures on the Failures tab came from.
struct FailureSource: Equatable {
    var label: String
    var date: Date
    var host: String
    /// Local result bundle, when there is one (not for remote runs).
    var resultBundle: URL?
}

@MainActor @Observable
final class ProjectModel {
    let project: Project
    let store: ProjectStore

    // Configuration
    private(set) var context: ProjectContext?
    private(set) var configError: String?
    private(set) var environment: TestEnvironment?
    private(set) var environmentError: String?
    /// What to know about the Xcode found, such as that the one at `developerDir` isn't the version CI pins.
    var environmentNotes: [String] { environment?.notes ?? [] }
    private(set) var modules: [String] = []
    private(set) var detectedBaseBranch: String?
    private(set) var currentBranch: String?
    /// Local branches plus origin's, for choosing the base branch.
    private(set) var branches: [String] = []
    var tab: ProjectTab = .snapshots
    /// Whether the window shows this project (set by the app model).
    @ObservationIgnored var isShown = false

    // Library
    private(set) var library: SnapshotLibrary? {
        didSet { libraryRevision &+= 1 }
    }
    private(set) var isLoadingLibrary = false
    /// Snapshots whose test no longer exists, by id.
    private(set) var orphanIDs: Set<String> = [] {
        didSet { libraryRevision &+= 1 }
    }
    var libraryFilter = "" {
        didSet { if oldValue != libraryFilter { keepSnapshotSelectionShown() } }
    }
    /// Bumped by ⌘F; the visible tab's filter field takes the cursor.
    var focusFilterRequest = 0
    /// Set by Re-record All Snapshot Tests… (toolbar, menu, ⌘K); the window asks before recording.
    var confirmReRecordAll = false
    var libraryScope = LibraryScope.all {
        didSet { if oldValue != libraryScope { keepSnapshotSelectionShown() } }
    }
    var librarySort = LibrarySort(rawValue: UserDefaults.app.string(forKey: "librarySort") ?? "") ?? .name {
        didSet { UserDefaults.app.set(librarySort.rawValue, forKey: "librarySort") }
    }
    var selectedSnapshotID: String? {
        didSet {
            guard oldValue != selectedSnapshotID else { return }
            // Keep comparing variants while stepping through the same test's variants.
            if case .variant(let other) = comparison, let now = selectedSnapshot,
               other.module == now.module, other.suite == now.suite, other.testName == now.testName { return }
            comparison = nil
        }
    }
    /// What is shown next to the selected snapshot: an earlier version or another variant.
    var comparison: SnapshotComparison?
    /// Whether the detail shows two images: a version, or another variant than the one selected
    /// (choosing the compared variant itself shows it alone).
    var isComparingSnapshot: Bool {
        switch comparison {
        case .version: true
        case .variant(let other): other.id != selectedSnapshotID
        case nil: false
        }
    }

    // Running
    private(set) var operation: RunOperation?
    private(set) var stageLabel: String = ""
    private(set) var phase: RunPhase = .preparing
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var skipped = 0
    private(set) var expectedTotal: Int?
    private(set) var currentTest: String?
    private(set) var log: [String] = []
    private(set) var lastResult: TestRunResult?
    private(set) var lastMessage: String?
    private(set) var lastMessageIsError = false
    /// Where the last message leads (the notice offers it as a button).
    private(set) var lastMessageAction: NoticeAction?
    /// Counts messages, so the same text said again ("All 12 tests passed.") is a new notice.
    private(set) var messageID = 0
    var showFullLog = false { didSet { recomputeVisibleLog() } }
    var logFilter = "" { didSet { recomputeVisibleLog() } }
    /// The log lines currently shown, kept up to date incrementally instead of re-filtering
    /// thousands of lines on every UI update during a run.
    private(set) var visibleLog: [String] = []
    /// When the current operation started (drives the elapsed-time display).
    private(set) var startedAt: Date?
    /// How long the last operation took.
    private(set) var lastDuration: TimeInterval?
    /// The number of tests in the last run of them all, which the next one measures its progress
    /// against (a re-record's verification or a flakiness check runs only some).
    @ObservationIgnored private var fullRunTotal: Int?

    // Failures
    private(set) var failures: [FailureItem] = [] {
        didSet {
            var byPath: [String: FailureItem] = [:]
            for item in failures { for path in item.referencePaths where byPath[path] == nil { byPath[path] = item } }
            failureByPath = byPath
            // A run that fixed the selected snapshot's test takes it out of the Failing scope.
            keepSnapshotSelectionShown()
        }
    }
    private(set) var failureSource: FailureSource?
    var selectedFailureID: String?
    /// Failures selected together with ⌘- or ⇧-click. `selectedFailureID` stays the one in focus;
    /// a set that no longer contains it (the selection moved by keyboard) no longer counts.
    var failureSelection: Set<String> = []
    private(set) var flakeResults: [FlakeResult] = []
    private(set) var historyFlaky: [FlakySignal] = []
    /// What kind of difference each failure is (first repetition), computed in the background.
    private(set) var diagnoses: [String: DiffDiagnosis] = [:]
    @ObservationIgnored private var diagnoseTask: Task<Void, Never>?
    /// All suites of the last run, read back from disk at launch (before any run in this session).
    private(set) var restoredSuites: [SuiteResult] = []
    /// The suites the Run tab's results list shows.
    /// This session's run, if there is one (also when it has no summary); else the one read from disk.
    var resultSuites: [SuiteResult] { lastResult.map { $0.summary?.suites ?? [] } ?? restoredSuites }
    /// Output while running, results once there are some.
    var runPane = RunPane.results
    private(set) var history: [RunRecord] = []

    // Changes
    private(set) var changeSet: SnapshotChangeSet? {
        didSet {
            changeKindByPath = Dictionary((changeSet?.changes ?? []).map { ($0.path, $0.kind) }, uniquingKeysWith: { a, _ in a })
            // A revert takes the selected snapshot out of the Changed scope.
            keepSnapshotSelectionShown()
        }
    }
    /// Lookups for the library's status marks, rebuilt when changes or failures change.
    private var changeKindByPath: [String: SnapshotChangeKind] = [:] {
        didSet { libraryRevision &+= 1 }
    }
    private var failureByPath: [String: FailureItem] = [:] {
        didSet { libraryRevision &+= 1 }
    }
    /// Bumped whenever anything the library's list order depends on changes (files, statuses,
    /// orphans), so the order is computed once per change instead of on every redraw.
    private var libraryRevision = 0
    private struct LibraryOrderKey: Equatable {
        var revision: Int, filter: String, scope: LibraryScope, sort: LibrarySort
    }
    @ObservationIgnored private var libraryOrderCache: (key: LibraryOrderKey, tree: [SnapshotModule], files: [SnapshotFile])?
    private(set) var changesError: String?
    var changeFilter = "" {
        didSet { if oldValue != changeFilter { keepChangeSelectionShown() } }
    }
    var changeKinds = Set(SnapshotChangeKind.allCases) {
        didSet { if oldValue != changeKinds { keepChangeSelectionShown() } }
    }
    var diffBase: DiffBase = .mergeBase { didSet { if oldValue != diffBase { refreshChanges() } } }
    var selectedChangeID: String?
    /// Changes marked as viewed whose file hasn't changed since.
    private(set) var viewedChanges: Set<String> = []
    var hideViewed = false {
        didSet { if oldValue != hideViewed { keepChangeSelectionShown() } }
    }
    /// What kind of difference each change is (base vs working tree), computed in the background.
    private(set) var changeDiagnoses: [String: DiffDiagnosis] = [:]
    @ObservationIgnored private var changeDiagnoseTask: Task<Void, Never>?
    private(set) var isLoadingChanges = false

    @ObservationIgnored private var cancelAction: (() -> Void)?
    /// The tab the current operation was started from.
    @ObservationIgnored private var operationTab: ProjectTab?
    private let lineBuffer = LineBatcher()
    private var lastFailingSuites: [SuiteResult] = []

    /// Image bytes for changes, used instead of git when set (previews and snapshot tests).
    @ObservationIgnored private var fixtureImages: [String: (Data?, Data?)]?
    @ObservationIgnored private var fixtureSnapshotImages: [String: Data]?
    @ObservationIgnored private var fixtureHistory: [String: [SnapshotVersion]]?
    @ObservationIgnored private var fixtureVersionImages: [String: Data]?

    init(project: Project, store: ProjectStore, autoload: Bool = true) {
        self.project = project
        self.store = store
        lineBuffer.onFlush = { [weak self] lines in self?.appendLog(lines) }
        if autoload {
            reload()
            watchSnapshots()
        }
    }

    /// Picks up snapshots written outside the app (a re-record from Xcode or the CLI) while the
    /// window is open. Runs of our own refresh when they finish instead.
    @ObservationIgnored private var watcher: SnapshotWatcher?
    private func watchSnapshots() {
        watcher = SnapshotWatcher(repository: project.url) { [weak self] in
            Task { @MainActor in
                guard let self, self.fixtureImages == nil, !self.isRunning else { return }
                self.refreshChanges()
            }
        }
    }

    var settings: ProjectSettings { store.settings(for: project) }
    var config: SnapshotConfig? { context?.config }
    var isRunning: Bool { operation != nil }
    var failingSuites: [SuiteResult] { lastFailingSuites }
    var hasRemote: Bool { !(config?.remoteHost ?? "").isEmpty }
    var baseBranch: String? { config?.baseBranch }

    // MARK: Loading

    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var environmentGeneration = 0

    /// Re-reads configuration, branches and history off the main thread (git and file I/O
    /// can take a while in large repositories), then refreshes everything that depends on them.
    @discardableResult
    func reload() -> Task<Void, Never> {
        reloadGeneration += 1
        let generation = reloadGeneration
        let url = project.url, settings = settings
        return Task {
            let loaded = await offCooperativePool {
                let git = Git(root: url)
                let context = Result { try ProjectModel.loadContext(url, settings: settings) }
                return (
                    branch: git.currentBranch(),
                    branches: ProjectModel.branchList(git),
                    context: context,
                    modules: (try? context.get())?.modules() ?? [],
                    history: RunHistory(repository: url).load(),
                    lastRunSaved: LastRun.savedDate(repository: url)
                )
            }
            // A newer reload (e.g. a quick second settings change) wins.
            guard generation == reloadGeneration else { return }
            // With the configuration, so the window never shows one without the other.
            currentBranch = loaded.branch
            branches = loaded.branches
            modules = loaded.modules
            setHistory(loaded.history)
            switch loaded.context {
            case .success(let ctx):
                context = ctx
                configError = nil
                detectedBaseBranch = ctx.resolved.config.baseBranch
            case .failure(let error):
                context = nil
                configError = error.localizedDescription
                detectedBaseBranch = nil
            }
            validateEnvironment()
            // Only a last run saved elsewhere since (or the first look): the app's own saves are what it
            // shows already, and taking them for an outside run cleared the session's verdicts.
            let savedElsewhere = loaded.lastRunSaved != lastRunSaved || failureSource == nil
            lastRunSaved = loaded.lastRunSaved
            if savedElsewhere { loadLastRun() }
            refreshChanges()
        }
    }

    /// When the last run on disk was saved, as of the last look at it.
    @ObservationIgnored private var lastRunSaved: Date?

    /// Saves the last run and notes when: coming back to the app reloads only a last run saved
    /// elsewhere (by `snapkit`). Taken for an outside run, the app's own save cleared the flakiness
    /// verdicts and the Run tab's result on the next activation.
    private func saveLastRun(_ save: (URL) -> Void) {
        save(project.url)
        lastRunSaved = LastRun.savedDate(repository: project.url)
    }

    /// Brings the project up to date when the app comes back to the front: commits, checkouts and
    /// snapshots may have changed meanwhile, and so may the last run and the history, when the tests
    /// ran in `snapkit`. Those are read again only if the last run was saved since. The task ends
    /// once they are.
    @discardableResult
    func refreshAfterActivation() -> Task<Void, Never> {
        guard !isRunning else { return Task {} }
        refreshChanges()
        guard fixtureImages == nil else { return Task {} }
        let url = project.url, known = lastRunSaved
        return Task {
            let changed = await offCooperativePool { () -> (saved: Date?, history: [RunRecord])? in
                let saved = LastRun.savedDate(repository: url)
                return saved == known ? nil : (saved, RunHistory(repository: url).load())
            }
            guard let (saved, history) = changed, !isRunning else { return }
            lastRunSaved = saved
            setHistory(history)
            loadLastRun()
        }
    }

    /// The repository's configuration. A folder deleted or moved while open would read as a project
    /// with no configuration, so that throws, as does git not running at all. `environment` is for git's process.
    nonisolated static func loadContext(_ url: URL, settings: ProjectSettings, environment: [String: String]? = nil) throws -> ProjectContext {
        guard FileManager.default.fileExists(atPath: url.path), try Git.repository(at: url, environment: environment) != nil else {
            throw RepositoryGone(url: url)
        }
        return try ProjectContext.load(repository: url, settings: settings)
    }

    /// Checks Xcode and the simulator the configuration asks for; without one, there is nothing to check.
    /// The task ends once the check is done, and its result shown unless a later check's is.
    @discardableResult
    func validateEnvironment() -> Task<Void, Never> {
        environmentGeneration += 1
        guard let config else {
            environment = nil
            environmentError = nil
            return Task {}
        }
        let generation = environmentGeneration
        return Task {
            let result = await offCooperativePool { Result { try EnvironmentValidator.validate(config) } }
            // A check of an earlier configuration must not land after the one now chosen.
            guard generation == environmentGeneration else { return }
            switch result {
            case .success(let env):
                environment = env
                environmentError = nil
            case .failure(let error):
                environment = nil
                environmentError = error.localizedDescription
            }
        }
    }

    /// Shows the last run on disk, unless what is shown is newer: a run of this session, or an
    /// imported bundle, which a reload (another base branch) must not replace.
    private func loadLastRun() {
        guard let last = LastRun.load(repository: project.url), failureSource.map({ last.date > $0.date }) ?? true else { return }
        // Newer than what is shown, so the tests ran elsewhere since (in `snapkit`): the Run tab's
        // results and the verdicts of earlier flakiness checks aren't this run's.
        lastResult = nil
        flakeResults = []
        lastFailingSuites = last.failingSuites
        restoredSuites = last.suites ?? []
        fullRunTotal = last.suites.map { $0.reduce(0) { $0 + $1.tests.count } }
        passed = last.passed
        failed = last.failed
        skipped = (last.suites ?? []).reduce(0) { $0 + $1.tests.filter { $0.outcome == .skipped }.count }
        setFailures(suites: last.failingSuites, images: last.failureImages(),
                    source: FailureSource(label: "Last run", date: last.date, host: last.host,
                                          resultBundle: last.resultBundle.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }))
    }

    nonisolated static func branchList(_ git: Git) -> [String] {
        let remote = (git.tryRun(["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin"]) ?? "")
            .split(separator: "\n").map(String.init)
            .compactMap { $0.hasPrefix("origin/") ? String($0.dropFirst(7)) : nil }
            .filter { $0 != "HEAD" }
        let all = Array(Set(git.localBranches() + remote))
        let preferred = ["develop", "main", "master"]
        return all.sorted { a, b in
            let ia = preferred.firstIndex(of: a) ?? Int.max, ib = preferred.firstIndex(of: b) ?? Int.max
            return ia == ib ? a.localizedStandardCompare(b) == .orderedAscending : ia < ib
        }
    }

    func setBaseBranch(_ branch: String?) {
        updateSettings { $0.baseBranch = branch }
    }

    func updateSettings(_ change: (inout ProjectSettings) -> Void) {
        store.updateSettings(for: project, change)
        reload()
    }

    // MARK: Changes

    /// Refreshes overlap (the file watcher, a run ending, coming back to the app); the latest one wins.
    @ObservationIgnored private var libraryGeneration = 0
    @ObservationIgnored private var changesGeneration = 0
    @ObservationIgnored private var branchesGeneration = 0

    /// Re-indexes the snapshots in the working tree (off the main thread).
    func refreshLibrary() {
        guard fixtureImages == nil else { return }
        isLoadingLibrary = true
        libraryGeneration += 1
        let generation = libraryGeneration, repo = project.url
        Task {
            let (loaded, orphans) = await offCooperativePool { () -> (SnapshotLibrary?, Set<String>) in
                let library = try? SnapshotLibrary.load(repository: repo)
                return (library, library.map { SnapshotLibrary.orphans($0.files, repository: repo) } ?? [])
            }
            guard generation == libraryGeneration else { return }
            isLoadingLibrary = false
            let shown = displayedSnapshots.map(\.id)
            library = loaded
            orphanIDs = orphans
            if !(loaded?.files.contains { $0.id == selectedSnapshotID } ?? false) {
                selectedSnapshotID = Self.replacement(for: selectedSnapshotID, shown: shown, now: displayedSnapshots.map(\.id))
            } else {
                keepSnapshotSelectionShown()        // still there, but committed or orphaned now, say
            }
        }
    }

    /// Re-reads the checked-out branch and the branch list (off the main thread): either can change
    /// outside the app, with a checkout in the terminal or a branch deleted on the remote.
    private func refreshBranches() {
        guard fixtureImages == nil else { return }
        branchesGeneration += 1
        let generation = branchesGeneration, repo = project.url
        Task {
            let (branch, all) = await offCooperativePool { () -> (String?, [String]) in
                let git = Git(root: repo)
                return (git.currentBranch(), ProjectModel.branchList(git))
            }
            guard generation == branchesGeneration else { return }
            if branch != currentBranch { currentBranch = branch }
            if all != branches { branches = all }
        }
    }

    var filteredSnapshots: [SnapshotFile] {
        let files = SnapshotLibrary.filter(library?.files ?? [], text: libraryFilter)
        switch libraryScope {
        case .all: return files
        case .changed: return files.filter { status(of: $0).change != nil }
        case .failing: return files.filter { status(of: $0).failureID != nil }
        case .uncommitted: return files.filter { $0.state != .clean }
        case .orphaned: return files.filter { orphanIDs.contains($0.id) }
        }
    }

    /// Changes and failures, keyed by snapshot path.
    func status(of file: SnapshotFile) -> SnapshotStatus {
        var status = SnapshotStatus()
        status.change = changeKindByPath[file.path]
        status.orphaned = orphanIDs.contains(file.id)
        if let failure = failureByPath[file.path] {
            status.failureID = failure.id
            status.verdict = failure.verdict
        }
        return status
    }

    func count(in scope: LibraryScope) -> Int {
        let files = library?.files ?? []
        switch scope {
        case .all: return files.count
        case .changed: return files.filter { status(of: $0).change != nil }.count
        case .failing: return files.filter { status(of: $0).failureID != nil }.count
        case .uncommitted: return files.filter { $0.state != .clean }.count
        case .orphaned: return orphanIDs.count
        }
    }

    /// How a file goes to the Trash: the Finder's, or a stand-in in tests, which must not fill the user's.
    @ObservationIgnored var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    /// Moves snapshots to the Trash (recoverable there, and git still has committed ones).
    func moveToTrash(_ files: [SnapshotFile]) {
        var moved = 0
        var failed: [String] = []
        var reason: String?
        for file in files {
            do {
                try trash(project.url.appendingPathComponent(file.path))
                moved += 1
            } catch {
                failed.append(file.fileName)
                reason = reason ?? error.localizedDescription
            }
        }
        ThumbnailCache.shared.removeAllObjects()
        if let reason {
            let notMoved = "Could not move \(failed.joined(separator: ", ")) to the Trash: \(reason)"
            notify(moved == 0 ? notMoved : "Moved \(moved) snapshot\(moved == 1 ? "" : "s") to the Trash. " + notMoved, isError: true)
        } else {
            notify("Moved \(moved) snapshot\(moved == 1 ? "" : "s") to the Trash.")
        }
        refreshChanges()
    }

    /// Shows a snapshot in the library, clearing filters that would hide it.
    func showInLibrary(path: String) {
        guard library?.files.contains(where: { $0.path == path }) == true else { return }
        libraryFilter = ""
        libraryScope = .all
        selectedSnapshotID = path
        tab = .snapshots
    }

    func isInLibrary(_ path: String) -> Bool {
        library?.files.contains { $0.path == path } ?? false
    }

    /// Opens a snapshot's change on the Changes tab, clearing filters that would hide it.
    func showChange(path: String) {
        guard let change = changeSet?.changes.first(where: { $0.path == path }) else { return }
        changeFilter = ""
        changeKinds.insert(change.kind)
        if viewedChanges.contains(change.id) { hideViewed = false }
        selectedChangeID = path
        tab = .changes
    }

    /// Snapshots in the order the list shows them: module, suite, test, variant.
    var displayedSnapshots: [SnapshotFile] { libraryOrder.files }

    /// The filtered library as module › suite › test, as the list groups it.
    var displayedTree: [SnapshotModule] { libraryOrder.tree }

    private var libraryOrder: (tree: [SnapshotModule], files: [SnapshotFile]) {
        let key = LibraryOrderKey(revision: libraryRevision, filter: libraryFilter, scope: libraryScope, sort: librarySort)
        if let cache = libraryOrderCache, cache.key == key { return (cache.tree, cache.files) }
        let filtered = filteredSnapshots
        let tree = SnapshotLibrary.tree(filtered)
        let files: [SnapshotFile] = switch librarySort {
        case .name: tree.flatMap { $0.suites.flatMap { $0.tests.flatMap(\.files) } }
        case .size: filtered.sorted { ($0.byteSize, $1.path) > ($1.byteSize, $0.path) }
        case .recent: filtered.sorted { ($0.modified ?? .distantPast, $1.path) > ($1.modified ?? .distantPast, $0.path) }
        }
        libraryOrderCache = (key, tree, files)
        return (tree, files)
    }

    var selectedSnapshot: SnapshotFile? {
        library?.files.first { $0.id == selectedSnapshotID }
    }

    /// Whether a snapshot's variant is worth showing: a name ("dark") always, a counter ("1") only
    /// when its test has more than one snapshot.
    func showsVariant(_ file: SnapshotFile) -> Bool {
        guard !file.variant.isEmpty else { return false }
        guard file.variant.allSatisfy(\.isNumber) else { return true }
        if multiSnapshotTests?.revision != libraryRevision {
            var counts: [String: Int] = [:]
            for f in library?.files ?? [] { counts[f.module + "/" + f.suite + "/" + f.testName, default: 0] += 1 }
            multiSnapshotTests = (libraryRevision, Set(counts.filter { $0.value > 1 }.keys))
        }
        return multiSnapshotTests?.tests.contains(file.module + "/" + file.suite + "/" + file.testName) ?? true
    }
    @ObservationIgnored private var multiSnapshotTests: (revision: Int, tests: Set<String>)?

    /// The other snapshots of the same test (light/dark, devices, named states), in variant order.
    func variants(of file: SnapshotFile) -> [SnapshotFile] {
        (library?.files ?? []).filter { $0.module == file.module && $0.suite == file.suite && $0.testName == file.testName }
            .sorted { $0.variant.localizedStandardCompare($1.variant) == .orderedAscending }
    }

    /// Committed versions of a snapshot, newest first (git log, off the main thread).
    func history(of file: SnapshotFile) async -> [SnapshotVersion] {
        if fixtureSnapshotImages != nil { return fixtureHistory?[file.path] ?? [] }
        let repo = project.url, path = file.path
        return await offCooperativePool { Git(root: repo).history(of: path) }
    }

    /// Loader for a snapshot as it was in `commit`; call off the main thread.
    func versionLoader(for file: SnapshotFile, commit: String) -> @Sendable () -> Data? {
        if let data = fixtureVersionImages?[commit + ":" + file.path] { return { data } }
        let git = Git(root: project.url), path = file.path
        return { git.image(of: path, at: commit) }
    }

    /// Bytes of a snapshot in the working tree; call off the main thread.
    func snapshotLoader(for file: SnapshotFile) -> @Sendable () -> Data? {
        if let data = fixtureSnapshotImages?[file.path] { return { data } }
        let url = project.url.appendingPathComponent(file.path)
        return { try? Data(contentsOf: url) }
    }

    func refreshChanges() {
        refreshLibrary()
        refreshBranches()
        changesGeneration += 1
        guard let base = baseBranch else {
            changeSet = nil
            changesError = "No base branch. Choose one from the branch menu above."
            isLoadingChanges = false
            return
        }
        isLoadingChanges = true
        let generation = changesGeneration, repo = project.url, against = diffBase
        Task {
            let result = await offCooperativePool {
                Result {
                    let set = try Git(root: repo).snapshotChanges(baseBranch: base, against: against)
                    return (set, ReviewMarks(repository: repo).viewed(in: set.changes))
                }
            }
            // An earlier base branch or diff base must not land after the one now chosen.
            guard generation == changesGeneration else { return }
            isLoadingChanges = false
            switch result {
            case .success(let (set, viewed)):
                let shown = displayedChanges.map(\.id)
                changeSet = set
                viewedChanges = viewed
                diagnoseChanges(set)
                changesError = nil
                if !set.changes.contains(where: { $0.id == selectedChangeID }) {
                    selectedChangeID = Self.replacement(for: selectedChangeID, shown: shown, now: displayedChanges.map(\.id))
                } else {
                    keepChangeSelectionShown()          // still there, but of a kind the list hides now, say
                }
            case .failure(let error):
                changeSet = nil
                changesError = error.localizedDescription
            }
        }
    }

    var filteredChanges: [SnapshotChange] {
        let changes = SnapshotChangeSet.filter(changeSet?.changes ?? [], text: changeFilter, kinds: changeKinds)
        return hideViewed ? changes.filter { !viewedChanges.contains($0.id) } : changes
    }

    /// Changes in the order the list shows them: grouped by suite.
    var displayedChanges: [SnapshotChange] {
        SnapshotChangeSet.group(filteredChanges).flatMap(\.changes)
    }

    /// Failures in the order the list shows them: grouped by suite.
    var displayedFailures: [FailureItem] {
        Dictionary(grouping: failures, by: \.suite.identifier).sorted { $0.key < $1.key }.flatMap(\.value)
    }

    /// What to select once `selected` is gone (trashed, discarded, reverted): the next row that was
    /// shown after it, else the one before it, else the first row shown now.
    private static func replacement(for selected: String?, shown: [String], now: [String]) -> String? {
        let remaining = Set(now)
        if let selected, let i = shown.firstIndex(of: selected),
           let next = shown[(i + 1)...].first(where: remaining.contains) ?? shown[..<i].last(where: remaining.contains) {
            return next
        }
        return now.first
    }

    /// What stays selected once a filter changed what the list shows: the selection while the list
    /// still shows it, else the first row shown. A list that shows nothing leaves it be, so typing
    /// through a filter that matches nothing for a moment doesn't lose it.
    private static func kept(_ selected: String?, shown: [String]) -> String? {
        guard let first = shown.first else { return selected }
        return selected.map(shown.contains) == true ? selected : first
    }

    private func keepSnapshotSelectionShown() {
        let kept = Self.kept(selectedSnapshotID, shown: displayedSnapshots.map(\.id))
        if kept != selectedSnapshotID { selectedSnapshotID = kept }
    }

    private func keepChangeSelectionShown() {
        let kept = Self.kept(selectedChangeID, shown: displayedChanges.map(\.id))
        if kept != selectedChangeID { selectedChangeID = kept }
    }

    /// Moves the selection in the current tab's list, from anywhere in the window.
    func selectAdjacent(_ step: Int) {
        func move(_ ids: [String], _ current: String?) -> String? {
            guard !ids.isEmpty else { return current }
            guard let current, let i = ids.firstIndex(of: current) else { return ids.first }
            return ids[min(max(i + step, 0), ids.count - 1)]
        }
        switch tab {
        case .failures: focusFailure(move(displayedFailures.map(\.id), selectedFailureID))
        case .changes: selectedChangeID = move(displayedChanges.map(\.id), selectedChangeID)
        case .snapshots: selectedSnapshotID = move(displayedSnapshots.map(\.id), selectedSnapshotID)
        case .run: break
        }
    }

    /// Shows a test from the run results on the Failures tab.
    func showFailure(_ id: String) {
        guard failures.contains(where: { $0.id == id }) else { return }
        focusFailure(id)
        tab = .failures
    }

    /// Selects just this failure, even when it was one of several selected.
    private func focusFailure(_ id: String?) {
        selectedFailureID = id
        failureSelection = []
    }

    /// Marks a change as viewed (or not). Marking moves on to the next unviewed change, so a
    /// review is one key press per snapshot.
    func setViewed(_ viewed: Bool, for change: SnapshotChange) {
        let order = displayedChanges
        if viewed { viewedChanges.insert(change.id) } else { viewedChanges.remove(change.id) }
        if fixtureImages == nil {
            ReviewMarks(repository: project.url).set(viewed, for: change, keepingOnly: changeSet?.changes ?? [])
        }
        guard viewed, selectedChangeID == change.id else { return }
        // The ones after it, then from the top; all of them when a filter hides it from the list.
        let rest = order.firstIndex(of: change).map { order[($0 + 1)...] + order[..<$0] } ?? order[...]
        let next = rest.first { !viewedChanges.contains($0.id) }
        if let next { selectedChangeID = next.id } else if hideViewed { selectedChangeID = nil }
    }

    /// Opens the test that records a snapshot in Xcode, at its function (via `xed`), or says why not.
    func openTestInXcode(_ file: SnapshotFile) {
        let repo = project.url
        Task {
            let location = await Task.detached { TestSourceLocator.locate(file, in: repo) }.value
            guard let location else {
                notify("No test file found for \(file.testName) (\(file.suite).swift).", isError: true)
                return
            }
            let url = repo.appendingPathComponent(location.path)
            let opened = await offCooperativePool { () -> Bool in
                let xed = Process()
                xed.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
                xed.arguments = (location.line.map { ["--line", String($0)] } ?? []) + [url.path]
                guard (try? xed.run()) != nil else { return false }
                xed.waitUntilExit()
                return xed.terminationStatus == 0
            }
            if !opened { NSWorkspace.shared.open(url) }
        }
    }

    /// Marks every change shown (after filters) as viewed or not, in one go.
    func setAllViewed(_ viewed: Bool) {
        let shown = displayedChanges
        guard !shown.isEmpty else { return }
        if viewed { viewedChanges.formUnion(shown.map(\.id)) } else { viewedChanges.subtract(shown.map(\.id)) }
        if fixtureImages == nil {
            ReviewMarks(repository: project.url).set(viewed, for: shown, keepingOnly: changeSet?.changes ?? [])
        }
        // Hiding viewed changes, every one shown is now gone from the list: the review is done.
        if viewed, hideViewed, shown.contains(where: { $0.id == selectedChangeID }) { selectedChangeID = nil }
    }

    var selectedChange: SnapshotChange? {
        changeSet?.changes.first { $0.id == selectedChangeID }
    }

    func fileURL(for change: SnapshotChange) -> URL {
        project.url.appendingPathComponent(change.path)
    }

    /// Where files for other apps to open go: base images, and an imported bundle's failure images.
    /// The temporary folder's, or a test's own.
    @ObservationIgnored var scratchDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotKit", isDirectory: true)

    /// Writes the base-side image to a temporary file (for opening in another app).
    func exportBaseImage(for change: SnapshotChange) -> URL? {
        guard let data = imageLoader(for: change)().0 else { return nil }
        // In the snapshot's own folder, so no other snapshot's base image (a test's second one, a
        // test of the same name in another suite) takes its place.
        let dir = scratchDirectory.appendingPathComponent("base-images", isDirectory: true)
            .appendingPathComponent((change.path as NSString).deletingLastPathComponent, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (change.fileName as NSString).deletingPathExtension
        let branch = (changeSet?.baseBranch ?? "base").replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("\(name) (\(branch)).png")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    /// Opens the base-side image in the default app, or says why it can't.
    func openBaseImage(for change: SnapshotChange) {
        guard let url = exportBaseImage(for: change) else {
            notify("Could not open the \(changeSet?.baseBranch ?? "base") version of \(change.fileName).", isError: true)
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Throws away a working-tree change to a snapshot (e.g. an unwanted re-record).
    func discard(_ change: SnapshotChange) {
        // Not while a run writes snapshots: its verification would check images thrown away meanwhile.
        guard !isRunning else { return }
        let git = Git(root: project.url)
        do {
            switch change.kind {
            case .uncommitted where git.tryRun(["cat-file", "-e", "HEAD:" + change.path]) == nil:
                // Deleted on this branch and recorded again: there is no version in HEAD to go back
                // to, so the file goes, as an untracked new one does.
                if !change.isUntracked { try git.run(["rm", "--cached", "--quiet", "--", change.path]) }
                try FileManager.default.removeItem(at: fileURL(for: change))
            case .uncommitted:
                try git.run(["restore", "--source=HEAD", "--staged", "--worktree", "--", change.path])
            case .new where git.tryRun(["ls-files", "--error-unmatch", "--", change.path]) == nil:
                try FileManager.default.removeItem(at: fileURL(for: change))
            default:
                return
            }
            ThumbnailCache.shared.removeAllObjects()
            ComparePairCache.shared.removeAllObjects()
            notify("Discarded the working-tree change to \(change.fileName).")
        } catch {
            notify("Could not discard \(change.fileName): \(error.localizedDescription)", isError: true)
        }
        refreshChanges()
    }

    /// Puts snapshots back the way the base branch has them (any kind of change: committed,
    /// uncommitted, new or deleted). Only the working tree changes; the result is there to commit.
    func revertToBase(_ changes: [SnapshotChange]) {
        guard let set = changeSet, !changes.isEmpty, !isRunning else { return }
        let repo = project.url
        Task {
            let result = await offCooperativePool { Result { try Git(root: repo).revertToBase(changes, in: set) } }
            ThumbnailCache.shared.removeAllObjects()
            ComparePairCache.shared.removeAllObjects()
            switch result {
            case .success:
                let what = changes.count == 1 ? changes[0].fileName : "\(changes.count) snapshots"
                notify("Reverted \(what) to \(set.baseBranch). Commit the result to keep it.")
            case .failure(let error):
                notify("Could not revert: \(error.localizedDescription)", isError: true)
            }
            refreshChanges()
        }
    }

    /// Uncommitted re-records with no visible difference to the base, per the diagnosis.
    var invisibleUncommitted: [SnapshotChange] {
        (changeSet?.changes ?? []).filter { $0.kind == .uncommitted && changeDiagnoses[$0.id]?.kind == .imperceptible }
    }

    /// Restores every uncommitted snapshot that looks the same as its committed version.
    func discardInvisibleChanges() {
        guard !isRunning else { return }
        let repo = project.url, changes = changeSet?.changes ?? []
        Task {
            let result = await offCooperativePool { () -> Result<Int, Error> in
                let git = Git(root: repo)
                let invisible = git.invisibleUncommittedChanges(changes)
                guard !invisible.isEmpty else { return .success(0) }
                return Result {
                    try git.run(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + invisible.map(\.path))
                    return invisible.count
                }
            }
            ThumbnailCache.shared.removeAllObjects()
            ComparePairCache.shared.removeAllObjects()
            switch result {
            case .success(let count):
                notify(count == 0 ? "No invisible re-records to discard."
                       : "Discarded \(count) re-recorded snapshot\(count == 1 ? "" : "s") with no visible change.")
            case .failure(let error):
                notify("Could not discard: \(error.localizedDescription)", isError: true)
            }
            refreshChanges()
        }
    }

    private func diagnoseChanges(_ set: SnapshotChangeSet) {
        changeDiagnoseTask?.cancel()
        let loaders = set.changes.prefix(300).filter { $0.kind != .new && $0.kind != .deleted }.map { ($0.id, imageLoader(for: $0)) }
        changeDiagnoseTask = Task {
            let result = await offCooperativePool {
                var out: [String: DiffDiagnosis] = [:]
                for (id, load) in loaders {
                    let (base, current) = load()
                    guard let a = base.flatMap(PixelImage.init(data:)), let b = current.flatMap(PixelImage.init(data:)) else { continue }
                    out[id] = DiffDiagnosis(ImageDiff.compare(a, b))
                }
                return out
            }
            guard !Task.isCancelled else { return }
            changeDiagnoses = result
        }
    }

    /// Whether `discard` applies: uncommitted edits and untracked new files only — never committed work.
    func canDiscard(_ change: SnapshotChange) -> Bool {
        switch change.kind {
        case .uncommitted: true
        case .new: change.isUntracked
        default: false
        }
    }

    /// Loader for the compare view; runs `git show`, so call it off the main thread.
    func imageLoader(for change: SnapshotChange) -> @Sendable () -> (Data?, Data?) {
        if let images = fixtureImages?[change.path] { return { images } }
        guard let set = changeSet else { return { (nil, nil) } }
        let git = Git(root: project.url)
        return { (git.baseImage(for: change, in: set), git.currentImage(for: change)) }
    }

    // MARK: Failures

    var selectedFailure: FailureItem? { failures.first { $0.id == selectedFailureID } }

    /// What the Failures list shows as selected: the multi-selection, or just the focused failure.
    var effectiveFailureSelection: Set<String> {
        if let id = selectedFailureID, failureSelection.contains(id), failureSelection.count > 1 { return failureSelection }
        return Set([selectedFailureID].compactMap { $0 })
    }

    /// The selected failures in list order.
    var selectedFailures: [FailureItem] {
        let ids = effectiveFailureSelection
        return displayedFailures.filter { ids.contains($0.id) }
    }

    /// Takes the list's selection: the focused failure stays focused while it is selected, else the
    /// first selected one in list order takes over.
    func selectFailures(_ ids: Set<String>) {
        failureSelection = ids
        if let id = selectedFailureID, ids.contains(id) { return }
        selectedFailureID = displayedFailures.first { ids.contains($0.id) }?.id
    }

    /// Diagnoses every failure's reference/actual pair off the main thread.
    private func diagnoseFailures() {
        diagnoseTask?.cancel()
        let items = failures
        diagnoseTask = Task {
            let result = await Task.detached { Self.diagnose(items) }.value
            guard !Task.isCancelled else { return }
            diagnoses = result
        }
    }

    nonisolated static func diagnose(_ items: [FailureItem]) -> [String: DiffDiagnosis] {
        var out: [String: DiffDiagnosis] = [:]
        for item in items {
            guard let image = item.images.min(by: { $0.repetition < $1.repetition }),
                  let ref = image.reference.flatMap({ FileManager.default.contents(atPath: $0.path) }).flatMap(PixelImage.init(data:)),
                  let act = image.failure.flatMap({ FileManager.default.contents(atPath: $0.path) }).flatMap(PixelImage.init(data:)) else { continue }
            out[item.id] = DiffDiagnosis(ImageDiff.compare(ref, act))
        }
        return out
    }

    /// Updates everything derived from the run history, including the failures' strips.
    private func setHistory(_ records: [RunRecord]) {
        history = records
        historyFlaky = RunHistory.flakySignals(records)
        let flaky = Dictionary(historyFlaky.map { ($0.test, $0) }, uniquingKeysWith: { a, _ in a })
        failures = failures.map { item in
            var item = item
            item.historyFlaky = flaky[item.id]
            item.timeline = RunHistory.timeline(for: item.id, in: records)
            return item
        }
    }

    private func setFailures(suites: [SuiteResult], images: [SnapshotFailureImages], source: FailureSource) {
        let flaky = Dictionary(historyFlaky.map { ($0.test, $0) }, uniquingKeysWith: { a, _ in a })
        let verdicts = Dictionary(flakeResults.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        failures = suites.flatMap { suite in
            suite.tests.filter { $0.outcome == .failed }.map { test in
                let id = suite.onlyTestingIdentifier(of: test)
                return FailureItem(
                    suite: suite,
                    test: test,
                    images: images.filter { $0.belong(to: test, in: suite) },
                    referencePaths: test.failureMessages.flatMap { FailureAttachments.referencePaths(in: $0, repository: project.url) },
                    verdict: verdicts[id]?.verdict,
                    historyFlaky: flaky[id],
                    timeline: RunHistory.timeline(for: id, in: history),
                    failingDevices: verdicts[id]?.failingDevices
                )
            }
        }
        failureSource = source
        diagnoseFailures()
        if selectedFailureID == nil || !failures.contains(where: { $0.id == selectedFailureID }) {
            selectedFailureID = displayedFailures.first?.id
        }
    }

    /// Opens an `.xcresult` (e.g. downloaded from CI) and shows its failures. The task ends once the
    /// notice says how it went.
    @discardableResult
    func importResultBundle(_ url: URL) -> Task<Void, Never> {
        // The run would replace it as it ends; its notice is hidden while the run goes on, too.
        guard !isRunning else {
            notify("Import the result bundle once the run has finished.", isError: true)
            return Task {}
        }
        notify("Reading \(url.lastPathComponent)…")
        let repo = project.url, start = tab
        let dir = scratchDirectory.appendingPathComponent("imported/\(UUID().uuidString)", isDirectory: true)
        // The Xcode CI runs, once found, rather than the selected one: an older xcresulttool can't
        // read a newer Xcode's bundles.
        let developerDir = environment?.xcode.developerDir
        return Task {
            let result = await offCooperativePool {
                Result { () -> (TestRunSummary, [SnapshotFailureImages]) in
                    let summary = try XCResultParser.load(resultBundle: url, developerDir: developerDir)
                    let images = (try? FailureAttachments.export(resultBundle: url, to: dir, developerDir: developerDir)) ?? []
                    return (summary, images)
                }
            }
            switch result {
            case .success(let (summary, images)):
                let runs = RunHistory(repository: repo)
                runs.append(RunRecord(kind: .imported, host: url.lastPathComponent, commit: nil, branch: nil, dirty: false,
                                      summary: summary, passed: summary.passed, failed: summary.failed, skipped: summary.skipped, resultBundle: url.path))
                setHistory(runs.load())
                lastFailingSuites = summary.failingSuites
                // Verdicts belong to the runs they came from, not to another machine's bundle.
                flakeResults = []
                setFailures(suites: summary.failingSuites, images: images,
                            source: FailureSource(label: url.lastPathComponent, date: Date(), host: "imported", resultBundle: url))
                notify("Imported \(summary.failed) failing test\(summary.failed == 1 ? "" : "s") from \(url.lastPathComponent).",
                       action: .showFailures)
                moveOn(to: .failures, from: start)
            case .failure(let error):
                notify("Could not read \(url.lastPathComponent): \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: Operations

    private func begin(_ op: RunOperation) -> Bool {
        guard operation == nil else { return false }
        operation = op
        operationTab = tab
        startedAt = Date()
        stageLabel = op.label
        runPane = .output
        phase = .preparing
        shownBeforeOperation = (passed, failed, skipped, lastDuration, lastResult?.resultBundle)
        passed = 0; failed = 0; skipped = 0
        expectedTotal = nil
        currentTest = nil
        log = []
        visibleLog = []
        notify(nil)
        NotificationCenter.default.post(name: AppModel.runStarted, object: nil)
        return true
    }

    /// Completed share of the tests, when the total is known (from the last run of the same scope).
    var progressFraction: Double? {
        guard isRunning, phase == .testing, let total = expectedTotal, total > 0 else { return nil }
        return min(Double(passed + failed + skipped) / Double(total), 1)
    }

    /// The Run tab's counts and duration when an operation began, put back if it's cancelled.
    @ObservationIgnored private var shownBeforeOperation: (passed: Int, failed: Int, skipped: Int, duration: TimeInterval?, result: URL?)?

    /// The notice after a cancel, which the Run tab marks as neither passed nor failed.
    static let cancelled = "Cancelled."
    var lastMessageIsCancellation: Bool { lastMessage == Self.cancelled }

    private func finish(message: String?, isError: Bool = false, action: NoticeAction? = nil) {
        lineBuffer.flushNow()
        if let shown = shownBeforeOperation, lastResult?.resultBundle == shown.result {
            // Nothing new to show (canceled, failed to start, didn't build, couldn't verify): the counts
            // went to zero when the operation began, so show again what was shown then, the last run's
            // (also one only read from disk, which has no `lastResult`), and how long it took.
            (passed, failed, skipped, lastDuration) = (shown.passed, shown.failed, shown.skipped, shown.duration)
        } else {
            lastDuration = startedAt.map { Date().timeIntervalSince($0) }
        }
        startedAt = nil
        operation = nil
        cancelAction = nil
        stageLabel = ""
        notify(message, isError: isError, action: action)
        if lastResult?.summary?.suites.isEmpty == false { runPane = .results }
        setHistory(RunHistory(repository: project.url).load())
        refreshChanges()
        announce(isError: isError)
        NotificationCenter.default.post(name: AppModel.runFinished, object: nil)
    }

    /// Ends an operation that threw. A cancel before xcodebuild started throws `CancellationError`,
    /// which is no failure.
    private func finish(throwing error: Error) {
        if error is CancellationError { finish(message: Self.cancelled) } else { finish(message: error.localizedDescription, isError: true) }
    }

    /// Shows `message` in the notice (nil hides it), with `action` as its next step. Always sets
    /// all three, so a message never inherits the button of the one before it.
    private func notify(_ message: String?, isError: Bool = false, action: NoticeAction? = nil) {
        lastMessage = message
        lastMessageIsError = isError
        lastMessageAction = action
        messageID &+= 1
    }

    /// Shows `next` once an action is done, if the user is still where they started it (on `start`,
    /// in this project). If they went elsewhere meanwhile, they stay there: the notice offers it.
    private func moveOn(to next: ProjectTab, from start: ProjectTab?) {
        if isShown, tab == start { tab = next }
    }

    /// What the Dock badge says: the failing tests, as Failures lists them (not a flakiness check's
    /// failed repetitions).
    var dockBadge: String? { failures.isEmpty ? nil : "\(failures.count)" }

    /// Dock badge (the open project's; the window keeps it in step as you switch, this also with the
    /// window closed), and a bounce when the run ends while you're elsewhere; VoiceOver reads the
    /// outcome where a sighted user sees the notice appear.
    private func announce(isError: Bool) {
        guard NSApp != nil, !DS.solidSurfaces else { return }
        if isShown { NSApp.dockTile.badgeLabel = dockBadge }
        if !NSApp.isActive { NSApp.requestUserAttention(isError ? .criticalRequest : .informationalRequest) }
        if let lastMessage, isShown {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: lastMessage.replacingOccurrences(of: "`", with: ""),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }

    func cancel() {
        stageLabel = "Cancelling…"
        cancelAction?()
    }

    private var onLine: @Sendable (String) -> Void {
        let buffer = lineBuffer
        return { line in buffer.add(line) }
    }

    private var onEvent: @Sendable (TestEvent, TestOutputParser) -> Void {
        { [weak self] event, parser in
            Task { @MainActor in
                guard let self else { return }
                self.passed = parser.passed
                self.failed = parser.failed
                self.skipped = parser.skipped
                switch event {
                case .phase(let p): self.phase = p
                case .testStarted(let name): self.currentTest = name
                default: break
                }
            }
        }
    }

    private func requireEnvironment() -> (ProjectContext, TestEnvironment)? {
        guard let context else {
            finish(message: configError ?? "Configuration could not be read.", isError: true)
            return nil
        }
        guard let environment else {
            finish(message: environmentError ?? "Xcode/simulator not checked yet.", isError: true)
            return nil
        }
        return (context, environment)
    }

    func runTests() {
        guard begin(.run), let (ctx, env) = requireEnvironment() else { return }
        expectedTotal = fullRunTotal
        let runner = TestRunner(repository: ctx.repository, config: ctx.config, environment: env)
        cancelAction = { runner.cancel() }
        let onLine = onLine, onEvent = onEvent
        Task {
            do {
                let result = try await runner.run(onLine: onLine, onEvent: onEvent)
                let (images, dir) = await Self.exportImages(of: result, developerDir: env.xcode.developerDir)
                completeRun(result, images: images, kind: .run, attachmentsDirectory: dir)
            } catch {
                finish(throwing: error)
            }
        }
    }

    /// A run's failure images, exported next to its result bundle, and the folder they are in.
    private nonisolated static func exportImages(of result: TestRunResult, developerDir: String) async
        -> (images: [SnapshotFailureImages], directory: URL?) {
        let dir = result.resultBundle.deletingPathExtension().appendingPathExtension("attachments")
        let images = await offCooperativePool {
            (try? FailureAttachments.export(resultBundle: result.resultBundle, to: dir, developerDir: developerDir)) ?? []
        }
        return (images, images.isEmpty ? nil : dir)
    }

    private func completeRun(_ result: TestRunResult, images: [SnapshotFailureImages], kind: RunKind, attachmentsDirectory: URL? = nil) {
        // A cancelled run's few results would stand in the Run tab beside the last run's failures
        // everywhere else; it keeps showing the last run (`finish` puts its counts back).
        if !result.cancelled {
            lastResult = result
            passed = result.passed
            failed = result.failed
            skipped = result.skipped
            RunHistory(repository: project.url).append(RunRecord.make(kind: kind, host: result.host, repository: project.url, result: result))
            setHistory(RunHistory(repository: project.url).load())
        }
        // A cancelled run has no results to speak of, nor one in which no test ran (the build failed):
        // the last run's failures stay.
        if kind == .run, !result.cancelled, result.nothingTested == nil {
            fullRunTotal = result.summary?.total
            saveLastRun { LastRun.update(with: result, attachmentsDirectory: attachmentsDirectory, repository: $0) }
            lastFailingSuites = result.failingSuites
            flakeResults = []
            setFailures(suites: result.failingSuites, images: images,
                        source: FailureSource(label: result.host == "local" ? "Local run" : "Remote run", date: Date(), host: result.host,
                                              resultBundle: result.host == "local" ? result.resultBundle : nil))
        }
        let message: String
        if result.cancelled { message = Self.cancelled }
        else if !result.buildErrors.isEmpty && result.summary == nil { message = "Build failed: \(result.buildErrors.first ?? "")" }
        else if result.failed > 0 { message = Self.failureTitle(tests: result.failed, suites: result.failingSuites.count) }
        else if result.nothingTested != nil { message = "No test ran." }
        else { message = result.passed == 1 ? "1 test passed." : "All \(result.passed) tests passed." }
        finish(message: message, isError: result.failed > 0 || (!result.succeeded && !result.cancelled) || result.nothingTested != nil,
               action: result.failed > 0 && !result.cancelled ? .showFailures : nil)
    }

    func reRecordFailed(suites: [SuiteResult]? = nil) {
        let targets = suites ?? lastFailingSuites
        guard !targets.isEmpty else {
            notify("No failing suites to re-record. Run the tests first.", isError: true)
            return
        }
        reRecord(suites: targets, onlyTesting: nil, what: targets.map(\.name).joined(separator: ", "))
    }

    /// Every snapshot whose test still exists (orphans have none left to run).
    var recordableSnapshots: [SnapshotFile] {
        library?.files.filter { !orphanIDs.contains($0.id) } ?? []
    }

    /// What "Re-record N Shown" records: the snapshots shown, less orphans (no test to run).
    var recordableShownSnapshots: [SnapshotFile] {
        displayedSnapshots.filter { !orphanIDs.contains($0.id) }
    }

    /// The number of tests behind `files`, for "Re-record 24 tests?".
    static func testCount(_ files: [SnapshotFile]) -> Int {
        Set(files.map { $0.module + "/" + $0.suite + "/" + $0.testName }).count
    }

    /// Re-records every snapshot test in the project, then verifies.
    func reRecordAll() {
        let files = recordableSnapshots
        guard !files.isEmpty else {
            notify("No snapshot tests to re-record yet. Run the tests to record the first ones.", isError: true)
            return
        }
        reRecord(files, granularity: .tests)
    }

    /// The snapshot behind the current tab's selection (a library file, a change, a failure's reference).
    var selectedSnapshotFile: SnapshotFile? {
        switch tab {
        case .snapshots: selectedSnapshot
        case .changes: selectedChange?.file
        case .failures: selectedFailure?.referencePaths.first.map { SnapshotFile(path: $0, byteSize: 0) }
        case .run: nil
        }
    }

    /// Names what ⇧⌘R will record: several failures can be selected at once.
    var reRecordSelectionTitle: String {
        tab == .failures && selectedFailures.count > 1 ? "Re-record \(selectedFailures.count) Selected Tests" : "Re-record Selected Test"
    }

    /// The selected snapshot's test exists to open (an orphan's is gone).
    var testToOpen: SnapshotFile? {
        selectedSnapshotFile.flatMap { orphanIDs.contains($0.id) ? nil : $0 }
    }

    var canReRecordSelection: Bool {
        guard !isRunning, environment != nil else { return false }
        switch tab {
        case .snapshots: return selectedSnapshot.map { !orphanIDs.contains($0.id) } ?? false
        case .changes: return selectedChange.map { $0.kind != .deleted && !orphanIDs.contains($0.id) } ?? false
        case .failures: return selectedFailure != nil
        case .run: return false
        }
    }

    /// Re-records the test of the selected snapshot, change or failure.
    func reRecordSelection() {
        guard canReRecordSelection else { return }
        switch tab {
        case .snapshots: if let file = selectedSnapshot { reRecord([file], granularity: .tests) }
        case .changes: if let change = selectedChange { reRecord([change.file], granularity: .tests) }
        case .failures: if !selectedFailures.isEmpty { reRecord(failures: selectedFailures) }
        case .run: break
        }
    }

    /// Re-records just these failing tests (not their whole suites), then verifies.
    func reRecord(failures items: [FailureItem]) {
        guard !items.isEmpty else { return }
        var suites: [SuiteResult] = []
        for item in items where !suites.contains(where: { $0.identifier == item.suite.identifier }) { suites.append(item.suite) }
        reRecord(suites: suites, onlyTesting: items.map(\.id),
                 what: items.count == 1 ? items[0].test.name : "\(items.count) tests")
    }

    /// Re-records the tests behind `files` (or their whole suites), then verifies.
    func reRecord(_ files: [SnapshotFile], granularity: RecordPlanner.Granularity) {
        guard !files.isEmpty, !isRunning else { return }
        let repo = project.url
        Task {
            let planned = await Task.detached { Result { try RecordPlanner.plan(files, granularity: granularity, repository: repo) } }.value
            switch planned {
            case .success(let selection):
                let tests = Set(files.map { $0.suite + "/" + $0.testName })
                let what = granularity == .suites
                    ? selection.suites.map(\.name).joined(separator: ", ")
                    : tests.count == 1 ? files[0].testName : "\(tests.count) tests"
                reRecord(suites: selection.suites, onlyTesting: selection.onlyTesting, what: what)
            case .failure(let error):
                notify("Can’t re-record: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func reRecord(suites targets: [SuiteResult], onlyTesting: [String]?, what: String) {
        guard begin(.rerecord), let (ctx, env) = requireEnvironment() else { return }
        let recorder = ReRecorder(runner: TestRunner(repository: ctx.repository, config: ctx.config, environment: env))
        cancelAction = { recorder.cancel() }
        let verify = store.settings.verifyAfterRecord
        let onLine = onLine, onEvent = onEvent
        Task {
            do {
                let outcome = try await recorder.reRecord(
                    suites: targets, onlyTesting: onlyTesting, verify: verify,
                    onStage: { stage in Task { @MainActor in self.stageLabel = stage.label } },
                    onLine: onLine, onEvent: onEvent)
                let record = outcome.recordRun
                if !record.cancelled {
                    RunHistory(repository: project.url).append(RunRecord.make(kind: .record, host: "local", repository: project.url, result: record))
                }
                var message = record.cancelled ? Self.cancelled : record.nothingTested.map { "Nothing was recorded: \($0)." } ?? "Re-recorded \(what)."
                var isError = record.nothingTested != nil
                if !outcome.restore.conflicts.isEmpty {
                    message += " WARNING: could not restore " + outcome.restore.conflicts.map { "\($0.path) (original at \($0.backup))" }.joined(separator: ", ")
                    isError = true
                }
                if let verifyRun = outcome.verifyRun,
                   let verified = await applyVerification(verifyRun, images: { await Self.exportImages(of: verifyRun, developerDir: env.xcode.developerDir) }) {
                    message += " " + verified.note
                    isError = isError || verified.isError
                }
                if outcome.verifyRun?.cancelled == true { message += " The verification was cancelled." }
                // A cancelled run's few results don't replace what the Run tab shows (see `completeRun`).
                if !record.cancelled, outcome.verifyRun?.cancelled != true { lastResult = outcome.verifyRun ?? record }
                // New references are working-tree changes: the next step is to look at them.
                finish(message: message, isError: isError, action: record.nothingTested == nil ? .reviewChanges : nil)
            } catch {
                finish(throwing: error)
            }
        }
    }

    /// Records a re-record's verification in the history and takes it into the last run, and says
    /// how it went; nil for a cancelled one. A cancelled verification has no results, nor one in
    /// which no test ran: the last run's failures stay. `images` exports the run's failure images.
    private func applyVerification(_ run: TestRunResult, images: () async -> (images: [SnapshotFailureImages], directory: URL?)) async
        -> (note: String, isError: Bool)? {
        guard !run.cancelled else { return nil }   // nor in the history: it ran some tests only
        RunHistory(repository: project.url).append(RunRecord.make(kind: .verify, host: run.host, repository: project.url, result: run))
        if let why = run.nothingTested { return ("Could not verify: \(why).", true) }
        let (images, directory) = await images()
        applyPartialRun(run, images: images, attachmentsDirectory: directory)
        return run.succeeded ? ("Verified: \(run.passed) passed.", false)
                             : ("Verification still fails (\(run.failed)) — the test may be flaky; try Check Flakiness.", true)
    }

    /// Takes in a run of some tests (a re-record's verification): those tests have their new
    /// results and images; the others keep the last run's, here and on disk.
    private func applyPartialRun(_ run: TestRunResult, images: [SnapshotFailureImages], attachmentsDirectory: URL?) {
        saveLastRun { LastRun.update(with: run, partial: true, attachmentsDirectory: attachmentsDirectory, repository: $0) }
        let ran = run.summary?.suites ?? []
        let rerun = Set(ran.flatMap { suite in suite.tests.map(suite.onlyTestingIdentifier) })
        lastFailingSuites = SuiteResult.merging(ran, into: lastFailingSuites).filter(\.isFailing)
        setFailures(suites: lastFailingSuites, images: failures.filter { !rerun.contains($0.id) }.flatMap(\.images) + images,
                    source: failureSource ?? FailureSource(label: "Verification run", date: Date(), host: run.host))
    }

    /// Reruns the failing suites — or just `tests` (`Bundle/Suite/test()`) — N times.
    /// The last run's failing tests, as `-only-testing` names them: a flakiness check repeats just
    /// those, not the passing tests beside them. (A suite whose tests aren't known stands for them.)
    var failingTestIdentifiers: [String] {
        lastFailingSuites.flatMap { suite in
            let failed = suite.tests.filter { $0.outcome == .failed }
            return failed.isEmpty ? suite.onlyTestingIdentifiers : failed.map { suite.onlyTestingIdentifier(of: $0) }
        }
    }

    func checkFlakiness(remote: Bool = false, tests: [String]? = nil) {
        let targets = lastFailingSuites
        guard !targets.isEmpty || tests != nil else {
            notify("No failing suites to check. Run the tests first.", isError: true)
            return
        }
        let iterations = store.settings.flakeIterations
        if remote {
            runRemote(.remoteFlakeCheck, mode: .flakeCheck(iterations: iterations), onlyTesting: tests ?? failingTestIdentifiers)
            return
        }
        guard begin(.flakeCheck), let (ctx, env) = requireEnvironment() else { return }
        let runner = TestRunner(repository: ctx.repository, config: ctx.config, environment: env)
        cancelAction = { runner.cancel() }
        let onLine = onLine, onEvent = onEvent
        Task {
            do {
                let result = try await runner.run(onlyTesting: tests ?? failingTestIdentifiers,
                                                  additionalArguments: Flakiness.arguments(iterations: iterations),
                                                  onLine: onLine, onEvent: onEvent)
                applyFlakeResult(result, iterations: iterations)
            } catch {
                finish(throwing: error)
            }
        }
    }

    private func applyFlakeResult(_ result: TestRunResult, iterations: Int) {
        // A cancelled check has repeated some tests only partly (its bundle has what ran): no verdicts,
        // and no place in the history.
        guard !result.cancelled else {
            finish(message: Self.cancelled)
            return
        }
        RunHistory(repository: project.url).append(RunRecord.make(kind: .flakeCheck, host: result.host, repository: project.url, result: result))
        setHistory(RunHistory(repository: project.url).load())
        // Tests that don't build were not checked, nor were they when no test ran: no verdicts either.
        if let why = result.nothingTested {
            finish(message: "Nothing was checked: \(why).", isError: true)
            return
        }
        guard let summary = result.summary else {
            finish(message: "Flakiness check produced no results.", isError: true)
            return
        }
        // Merge, so checking one test keeps verdicts for the others.
        let checked = Flakiness.classify(summary)
        var merged = Dictionary(flakeResults.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in checked { merged[r.id] = r }
        flakeResults = merged.values.sorted { $0.id < $1.id }
        lastResult = result
        passed = checked.reduce(0) { $0 + $1.passed }
        failed = checked.reduce(0) { $0 + $1.failed }
        failures = failures.map { item in
            var item = item
            let flake = flakeResults.first { $0.id == item.id }
            item.verdict = flake?.verdict
            item.failingDevices = flake?.failingDevices
            return item
        }
        // What this check found: earlier checks' verdicts are not its news.
        let flaky = checked.filter { $0.verdict == .flaky }.count
        let onSome = checked.filter { $0.failingDevices != nil }.count
        let always = checked.filter { $0.verdict == .alwaysFails }.count - onSome
        let passing = checked.count - always - onSome - flaky
        let start = operationTab
        finish(message: "\(iterations)× on \(result.host): \(always) fail\(always == 1 ? "s" : "") every time, "
                + (onSome > 0 ? "\(onSome) only on some devices, " : "")
                + "\(flaky) flaky, \(passing) pass\(passing == 1 ? "es" : "").",
               action: .showFailures)
        moveOn(to: .failures, from: start)
    }

    func runRemote() {
        runRemote(.remoteRun, mode: .run, onlyTesting: nil)
    }

    /// How remote runs reach the Mac they run on: `remoteHost`'s transport, or a stand-in in tests.
    @ObservationIgnored var remoteTransport: (SnapshotConfig) throws -> any RemoteTransport = { try $0.remoteTransport() }

    func reRecordOnRemote() {
        guard !lastFailingSuites.isEmpty else {
            notify("No failing suites to re-record. Run the tests first.", isError: true)
            return
        }
        runRemote(.remoteRecord, mode: .record(suites: lastFailingSuites), onlyTesting: nil)
    }

    private func runRemote(_ op: RunOperation, mode: RemoteMode, onlyTesting: [String]?) {
        guard begin(op) else { return }
        guard let ctx = context else { finish(message: configError ?? "No configuration.", isError: true); return }
        let transport: RemoteTransport
        do { transport = try remoteTransport(ctx.config) } catch { finish(message: error.localizedDescription, isError: true); return }
        let runner = RemoteRunner(repository: ctx.repository, config: ctx.config, transport: transport)
        cancelAction = { runner.cancel() }
        let verify = store.settings.verifyAfterRecord
        let onLine = onLine, onEvent = onEvent
        let onStage: @Sendable (RemoteStage) -> Void = { stage in Task { @MainActor in self.stageLabel = "\(transport.label): \(stage.label)" } }
        Task {
            do {
                let out = try await runner.run(mode: mode, onlyTesting: onlyTesting, onStage: onStage, onLine: onLine, onEvent: onEvent)
                switch mode {
                case .run:
                    completeRun(out.run, images: out.attachments, kind: .run, attachmentsDirectory: out.attachmentsDirectory)
                case .flakeCheck(let n):
                    applyFlakeResult(out.run, iterations: n)
                case .record(let suites):
                    if !out.run.cancelled {
                        RunHistory(repository: project.url).append(RunRecord.make(kind: .record, host: out.host, repository: project.url, result: out.run))
                    }
                    if let why = out.run.nothingTested {
                        finish(message: "Nothing was recorded: \(why).", isError: true)
                    } else if out.run.cancelled {
                        finish(message: Self.cancelled)
                    } else {
                        let start = operationTab, count = out.downloadedSnapshots.count
                        var message = "Recorded on \(out.host); downloaded \(count) snapshot\(count == 1 ? "" : "s").", isError = false
                        // The Run tab shows the verification, as for a local re-record; the record run
                        // when there is none to show (not asked for, or it couldn't run).
                        if !verify { lastResult = out.run }
                        // Verified where it was recorded, as `snapkit rerecord --remote` does.
                        if verify {
                            do {
                                let checked = try await runner.run(mode: .run, onlyTesting: suites.flatMap(\.onlyTestingIdentifiers),
                                                                   onStage: onStage, onLine: onLine, onEvent: onEvent)
                                if checked.run.cancelled { message += " The verification was cancelled." }
                                else { lastResult = checked.run }
                                if let verified = await applyVerification(checked.run, images: { (checked.attachments, checked.attachmentsDirectory) }) {
                                    message += " " + verified.note
                                    isError = verified.isError
                                }
                            } catch is CancellationError {
                                message += " The verification was cancelled."
                            } catch {
                                lastResult = out.run
                                message += " Could not verify: \(error.localizedDescription)"
                                isError = true
                            }
                        }
                        finish(message: message, isError: isError, action: .reviewChanges)
                        moveOn(to: .changes, from: start)
                    }
                }
            } catch {
                finish(throwing: error)
            }
        }
    }

    static func failureTitle(tests: Int, suites: Int) -> String {
        let t = tests == 1 ? "1 failing test" : "\(tests) failing tests"
        return suites > 0 ? t + (suites == 1 ? " in 1 suite" : " in \(suites) suites") : t
    }

    // MARK: Log

    static let maxLogLines = 8000

    func appendLog(_ lines: [String]) {
        log.append(contentsOf: lines)
        // Trim in chunks so the full re-filter happens rarely, not on every batch.
        if log.count > Self.maxLogLines + 1000 {
            log.removeFirst(log.count - Self.maxLogLines)
            recomputeVisibleLog()
        } else {
            visibleLog.append(contentsOf: lines.filter(isVisible))
        }
    }

    private func isVisible(_ line: String) -> Bool {
        guard showFullLog || Self.isInteresting(line) else { return false }
        let query = logFilter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || line.localizedCaseInsensitiveContains(query)
    }

    private func recomputeVisibleLog() {
        visibleLog = log.filter(isVisible)
    }

    static func isInteresting(_ line: String) -> Bool {
        line.hasPrefix("$ ") || line.hasPrefix("snapkit:") || line.hasPrefix("◇ Suite") || line.hasPrefix("◇ Test") || line.hasPrefix("✔") || line.hasPrefix("✘")
            || line.hasPrefix("↳ ") || line.hasPrefix("** ") || line.contains(": error: ") || line.hasPrefix("Test Case '") || line.hasPrefix("Test case '")
            || line.hasPrefix("Testing started") || line.hasPrefix("Resolve Package Graph")
    }
}

// MARK: - Fixtures (snapshot tests)

/// A complete, side-effect-free state for rendering project views deterministically.
struct ProjectFixture {
    var context: ProjectContext?
    var environment: TestEnvironment?
    var environmentError: String?
    var configError: String?
    var changesError: String?
    var modules: [String] = []
    var detectedBaseBranch: String?
    var currentBranch: String?
    var branches: [String] = ["develop", "main", "feature/checkout-redesign"]
    var tab: ProjectTab = .run
    var library: SnapshotLibrary?
    var snapshotImages: [String: Data] = [:]
    var orphanIDs: Set<String> = []
    var history: [String: [SnapshotVersion]] = [:]
    /// Keyed "commit:path".
    var versionImages: [String: Data] = [:]
    var operation: RunOperation?
    var stageLabel = ""
    var phase: RunPhase = .preparing
    var passed = 0
    var failed = 0
    var skipped = 0
    var expectedTotal: Int?
    var currentTest: String?
    var log: [String] = []
    var lastResult: TestRunResult?
    var lastMessage: String?
    var lastMessageIsError = false
    var lastMessageAction: NoticeAction?
    var startedAt: Date?
    var lastDuration: TimeInterval?
    var failingSuites: [SuiteResult] = []
    var failures: [FailureItem] = []
    var failureSource: FailureSource?
    var flakeResults: [FlakeResult] = []
    var historyFlaky: [FlakySignal] = []
    var changeSet: SnapshotChangeSet?
    var changeImages: [String: (Data?, Data?)] = [:]
    var viewedChanges: Set<String> = []
}

extension ProjectModel {
    func apply(_ f: ProjectFixture) {
        context = f.context
        configError = f.configError
        environment = f.environment
        environmentError = f.environmentError
        modules = f.modules
        detectedBaseBranch = f.detectedBaseBranch ?? f.context?.config.baseBranch
        currentBranch = f.currentBranch
        branches = f.branches
        tab = f.tab
        operation = f.operation
        stageLabel = f.stageLabel
        phase = f.phase
        passed = f.passed
        failed = f.failed
        skipped = f.skipped
        expectedTotal = f.expectedTotal
        currentTest = f.currentTest
        log = f.log
        recomputeVisibleLog()
        lastResult = f.lastResult
        fullRunTotal = f.lastResult?.summary?.total
        runPane = f.operation == nil ? .results : .output
        notify(f.lastMessage, isError: f.lastMessageIsError, action: f.lastMessageAction)
        startedAt = f.startedAt
        lastDuration = f.lastDuration
        lastFailingSuites = f.failingSuites
        flakeResults = f.flakeResults
        historyFlaky = f.historyFlaky
        failures = f.failures
        diagnoses = Self.diagnose(f.failures)
        failureSource = f.failureSource
        selectedFailureID = displayedFailures.first?.id
        changeSet = f.changeSet
        changesError = f.changesError
        isLoadingChanges = false
        fixtureImages = f.changeImages
        library = f.library
        orphanIDs = f.orphanIDs
        fixtureSnapshotImages = f.snapshotImages
        fixtureHistory = f.history
        fixtureVersionImages = f.versionImages
        selectedSnapshotID = displayedSnapshots.first?.id
        viewedChanges = f.viewedChanges
        changeDiagnoses = Dictionary(uniqueKeysWithValues: (f.changeSet?.changes ?? []).compactMap { change -> (String, DiffDiagnosis)? in
            guard let (a, b) = f.changeImages[change.path], let pa = a.flatMap(PixelImage.init(data:)),
                  let pb = b.flatMap(PixelImage.init(data:)) else { return nil }
            return (change.id, DiffDiagnosis(ImageDiff.compare(pa, pb)))
        })
        selectedChangeID = displayedChanges.first?.id
    }
}

/// Collects lines from background threads and hands them to the main actor in batches.
final class LineBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var scheduled = false
    var onFlush: (@MainActor ([String]) -> Void)?

    func add(_ line: String) {
        lock.lock()
        pending.append(line)
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.flushNow()
            }
        }
    }

    @MainActor func flushNow() {
        lock.lock()
        let lines = pending
        pending = []
        scheduled = false
        lock.unlock()
        if !lines.isEmpty { onFlush?(lines) }
    }
}

/// Where a notice can take you next.
enum NoticeAction: Equatable {
    case reviewChanges, showFailures

    var title: String {
        switch self {
        case .reviewChanges: "Review Changes"
        case .showFailures: "Show Failures"
        }
    }

    var tab: ProjectTab {
        switch self {
        case .reviewChanges: .changes
        case .showFailures: .failures
        }
    }
}
