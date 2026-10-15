import AppKit
import Foundation
import SnapshotKitCore

enum ProjectTab: String, CaseIterable, Identifiable {
    case run = "Run"
    case failures = "Failures"
    case changes = "Changes"
    var id: String { rawValue }
}

enum RunOperation: Equatable {
    case run, rerecord, flakeCheck
    case remoteRun, remoteRecord, remoteFlakeCheck

    var label: String {
        switch self {
        case .run: "Running tests"
        case .rerecord: "Re-recording failed suites"
        case .flakeCheck: "Checking flakiness"
        case .remoteRun: "Running on remote"
        case .remoteRecord: "Re-recording on remote"
        case .remoteFlakeCheck: "Checking flakiness on remote"
        }
    }

    var isRemote: Bool { [.remoteRun, .remoteRecord, .remoteFlakeCheck].contains(self) }
}

/// A failing test with everything needed to investigate it.
struct FailureItem: Identifiable, Hashable {
    var suite: SuiteResult
    var test: TestCaseResult
    var images: [SnapshotFailureImages]
    var referencePaths: [String]
    var verdict: FlakeVerdict?
    var historyFlaky: FlakySignal?
    var id: String { suite.identifier + "/" + test.name }
}

/// Where the failures on the Failures tab came from.
struct FailureSource: Equatable {
    var label: String
    var date: Date
    var host: String
}

@MainActor
final class ProjectModel: ObservableObject {
    let project: Project
    let store: ProjectStore

    // Configuration
    @Published private(set) var context: ProjectContext?
    @Published private(set) var configError: String?
    @Published private(set) var environment: TestEnvironment?
    @Published private(set) var environmentError: String?
    @Published private(set) var modules: [String] = []
    @Published private(set) var detectedBaseBranch: String?
    @Published private(set) var currentBranch: String?
    @Published var tab: ProjectTab = .run

    // Running
    @Published private(set) var operation: RunOperation?
    @Published private(set) var stageLabel: String = ""
    @Published private(set) var phase: RunPhase = .preparing
    @Published private(set) var passed = 0
    @Published private(set) var failed = 0
    @Published private(set) var skipped = 0
    @Published private(set) var expectedTotal: Int?
    @Published private(set) var currentTest: String?
    @Published private(set) var log: [String] = []
    @Published private(set) var lastResult: TestRunResult?
    @Published private(set) var lastMessage: String?
    @Published private(set) var lastMessageIsError = false
    @Published var showFullLog = false

    // Failures
    @Published private(set) var failures: [FailureItem] = []
    @Published private(set) var failureSource: FailureSource?
    @Published var selectedFailureID: String?
    @Published private(set) var flakeResults: [FlakeResult] = []
    @Published private(set) var historyFlaky: [FlakySignal] = []

    // Changes
    @Published private(set) var changeSet: SnapshotChangeSet?
    @Published private(set) var changesError: String?
    @Published var changeFilter = ""
    @Published var changeKinds = Set(SnapshotChangeKind.allCases)
    @Published var diffBase: DiffBase = .mergeBase { didSet { if oldValue != diffBase { refreshChanges() } } }
    @Published var selectedChangeID: String?
    @Published private(set) var isLoadingChanges = false

    private var cancelAction: (() -> Void)?
    private let lineBuffer = LineBatcher()
    private var lastFailingSuites: [SuiteResult] = []

    /// Image bytes for changes, used instead of git when set (previews and snapshot tests).
    private var fixtureImages: [String: (Data?, Data?)]?

    init(project: Project, store: ProjectStore, autoload: Bool = true) {
        self.project = project
        self.store = store
        lineBuffer.onFlush = { [weak self] lines in self?.appendLog(lines) }
        if autoload { reload() }
    }

    var settings: ProjectSettings { store.settings(for: project) }
    var config: SnapshotConfig? { context?.config }
    var isRunning: Bool { operation != nil }
    var failingSuites: [SuiteResult] { lastFailingSuites }
    var hasRemote: Bool { !(config?.remoteHost ?? "").isEmpty }
    var baseBranch: String? { config?.baseBranch }

    // MARK: Loading

    func reload() {
        currentBranch = Git(root: project.url).currentBranch()
        do {
            let ctx = try ProjectContext.load(repository: project.url, settings: settings)
            context = ctx
            configError = nil
            modules = ctx.modules()
            detectedBaseBranch = ctx.resolved.config.baseBranch
        } catch {
            context = nil
            configError = error.localizedDescription
        }
        validateEnvironment()
        loadLastRun()
        historyFlaky = RunHistory.flakySignals(RunHistory(repository: project.url).load())
        refreshChanges()
    }

    func validateEnvironment() {
        guard let config else { return }
        Task {
            let result = await Task.detached { Result { try EnvironmentValidator.validate(config) } }.value
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

    private func loadLastRun() {
        guard let last = LastRun.load(repository: project.url) else { return }
        lastFailingSuites = last.failingSuites
        passed = last.passed
        failed = last.failed
        let attachmentsDir = last.attachmentsDirectory.map { URL(fileURLWithPath: $0) }
            ?? last.resultBundle.map { URL(fileURLWithPath: $0).deletingPathExtension().appendingPathExtension("attachments") }
        var images: [SnapshotFailureImages] = []
        if let dir = attachmentsDir, let manifest = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) {
            images = (try? FailureAttachments.parse(manifest: manifest, directory: dir)) ?? []
        }
        setFailures(suites: last.failingSuites, images: images,
                    source: FailureSource(label: "Last run", date: last.date, host: last.host))
    }

    func updateSettings(_ change: (inout ProjectSettings) -> Void) {
        store.updateSettings(for: project, change)
        reload()
    }

    // MARK: Changes

    func refreshChanges() {
        guard let base = baseBranch else {
            changeSet = nil
            changesError = "No base branch. Set one in the project settings."
            return
        }
        isLoadingChanges = true
        let repo = project.url, against = diffBase
        Task {
            let result = await Task.detached { Result { try Git(root: repo).snapshotChanges(baseBranch: base, against: against) } }.value
            isLoadingChanges = false
            switch result {
            case .success(let set):
                changeSet = set
                changesError = nil
                if selectedChangeID == nil || !set.changes.contains(where: { $0.id == selectedChangeID }) {
                    selectedChangeID = filteredChanges.first?.id
                }
            case .failure(let error):
                changeSet = nil
                changesError = error.localizedDescription
            }
        }
    }

    var filteredChanges: [SnapshotChange] {
        SnapshotChangeSet.filter(changeSet?.changes ?? [], text: changeFilter, kinds: changeKinds)
    }

    var selectedChange: SnapshotChange? {
        changeSet?.changes.first { $0.id == selectedChangeID }
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

    private func setFailures(suites: [SuiteResult], images: [SnapshotFailureImages], source: FailureSource) {
        let flaky = Dictionary(historyFlaky.map { ($0.test, $0) }, uniquingKeysWith: { a, _ in a })
        let verdicts = Dictionary(flakeResults.map { ($0.id, $0.verdict) }, uniquingKeysWith: { a, _ in a })
        failures = suites.flatMap { suite in
            suite.tests.filter { $0.outcome == .failed }.map { test in
                FailureItem(
                    suite: suite,
                    test: test,
                    images: images.filter { $0.testIdentifier == test.identifier },
                    referencePaths: test.failureMessages.flatMap { FailureAttachments.referencePaths(in: $0, repository: project.url) },
                    verdict: verdicts[suite.identifier + "/" + test.name],
                    historyFlaky: flaky[suite.identifier + "/" + test.name]
                )
            }
        }
        failureSource = source
        if selectedFailureID == nil || !failures.contains(where: { $0.id == selectedFailureID }) {
            selectedFailureID = failures.first?.id
        }
    }

    /// Opens an `.xcresult` (e.g. downloaded from CI) and shows its failures.
    func importResultBundle(_ url: URL) {
        lastMessage = "Reading \(url.lastPathComponent)…"
        lastMessageIsError = false
        let repo = project.url
        Task {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotKit/imported/\(UUID().uuidString)")
            let result = await Task.detached {
                Result { () -> (TestRunSummary, [SnapshotFailureImages]) in
                    let summary = try XCResultParser.load(resultBundle: url, developerDir: nil)
                    let images = (try? FailureAttachments.export(resultBundle: url, to: dir, developerDir: nil)) ?? []
                    return (summary, images)
                }
            }.value
            do {
                switch result {
                case .success(let (summary, images)):
                    RunHistory(repository: repo).append(RunRecord(kind: .imported, host: url.lastPathComponent, commit: nil, branch: nil, dirty: false,
                                                                  summary: summary, passed: summary.passed, failed: summary.failed, skipped: summary.skipped, resultBundle: url.path))
                    self.lastFailingSuites = summary.failingSuites
                    self.setFailures(suites: summary.failingSuites, images: images,
                                     source: FailureSource(label: url.lastPathComponent, date: Date(), host: "imported"))
                    self.lastMessage = "Imported \(summary.failed) failing test(s) from \(url.lastPathComponent)."
                    self.tab = .failures
                case .failure(let error):
                    self.lastMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
                    self.lastMessageIsError = true
                }
            }
        }
    }

    // MARK: Operations

    private func begin(_ op: RunOperation) -> Bool {
        guard operation == nil else { return false }
        operation = op
        stageLabel = op.label
        phase = .preparing
        passed = 0; failed = 0; skipped = 0
        currentTest = nil
        log = []
        lastMessage = nil
        lastMessageIsError = false
        return true
    }

    private func finish(message: String?, isError: Bool = false) {
        lineBuffer.flushNow()
        operation = nil
        cancelAction = nil
        stageLabel = ""
        lastMessage = message
        lastMessageIsError = isError
        historyFlaky = RunHistory.flakySignals(RunHistory(repository: project.url).load())
        currentBranch = Git(root: project.url).currentBranch()
        refreshChanges()
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
        expectedTotal = lastResult?.summary?.total
        let runner = TestRunner(repository: ctx.repository, config: ctx.config, environment: env)
        cancelAction = { runner.cancel() }
        let onLine = onLine, onEvent = onEvent
        Task {
            do {
                let result = try await runner.run(onLine: onLine, onEvent: onEvent)
                let dir = result.resultBundle.deletingPathExtension().appendingPathExtension("attachments")
                let images = await Task.detached {
                    (try? FailureAttachments.export(resultBundle: result.resultBundle, to: dir, developerDir: env.xcode.developerDir)) ?? []
                }.value
                completeRun(result, images: images, kind: .run, attachmentsDirectory: images.isEmpty ? nil : dir)
            } catch {
                finish(message: error.localizedDescription, isError: true)
            }
        }
    }

    private func completeRun(_ result: TestRunResult, images: [SnapshotFailureImages], kind: RunKind, attachmentsDirectory: URL? = nil) {
        lastResult = result
        passed = result.passed
        failed = result.failed
        skipped = result.skipped
        RunHistory(repository: project.url).append(RunRecord.make(kind: kind, host: result.host, repository: project.url, result: result))
        historyFlaky = RunHistory.flakySignals(RunHistory(repository: project.url).load())
        if kind == .run {
            LastRun(result: result, attachmentsDirectory: attachmentsDirectory).save(repository: project.url)
            lastFailingSuites = result.failingSuites
            flakeResults = []
            setFailures(suites: result.failingSuites, images: images,
                        source: FailureSource(label: result.host == "local" ? "Local run" : "Remote run", date: Date(), host: result.host))
        }
        let message: String
        if result.cancelled { message = "Cancelled." }
        else if !result.buildErrors.isEmpty && result.summary == nil { message = "Build failed: \(result.buildErrors.first ?? "")" }
        else if result.failed > 0 { message = "\(result.failed) failing test(s) in \(result.failingSuites.count) suite(s): \(result.failingSuites.map(\.name).joined(separator: ", "))" }
        else { message = "All \(result.passed) tests passed." }
        finish(message: message, isError: result.failed > 0 || (!result.succeeded && !result.cancelled))
    }

    func reRecordFailed(suites: [SuiteResult]? = nil) {
        let targets = suites ?? lastFailingSuites
        guard !targets.isEmpty else {
            lastMessage = "No failing suites to re-record. Run the tests first."
            lastMessageIsError = true
            return
        }
        guard begin(.rerecord), let (ctx, env) = requireEnvironment() else { return }
        let recorder = ReRecorder(runner: TestRunner(repository: ctx.repository, config: ctx.config, environment: env))
        cancelAction = { recorder.cancel() }
        let verify = store.settings.verifyAfterRecord
        let onLine = onLine, onEvent = onEvent
        Task {
            do {
                let outcome = try await recorder.reRecord(
                    suites: targets, verify: verify,
                    onStage: { stage in Task { @MainActor in self.stageLabel = stage.label } },
                    onLine: onLine, onEvent: onEvent)
                RunHistory(repository: project.url).append(RunRecord.make(kind: .record, host: "local", repository: project.url, result: outcome.recordRun))
                var message = "Re-recorded \(targets.map(\.name).joined(separator: ", "))."
                var isError = false
                if !outcome.restore.conflicts.isEmpty {
                    message += " WARNING: could not restore " + outcome.restore.conflicts.map { "\($0.path) (original at \($0.backup))" }.joined(separator: ", ")
                    isError = true
                }
                if let verifyRun = outcome.verifyRun {
                    RunHistory(repository: project.url).append(RunRecord.make(kind: .verify, host: "local", repository: project.url, result: verifyRun))
                    LastRun(result: verifyRun).save(repository: project.url)
                    lastFailingSuites = verifyRun.failingSuites
                    setFailures(suites: verifyRun.failingSuites, images: [], source: FailureSource(label: "Verification run", date: Date(), host: "local"))
                    if verifyRun.succeeded {
                        message += " Verified: \(verifyRun.passed) passed."
                    } else if !verifyRun.cancelled {
                        message += " Verification still fails (\(verifyRun.failed)) — the test may be flaky; try Check flakiness."
                        isError = true
                    }
                }
                lastResult = outcome.verifyRun ?? outcome.recordRun
                finish(message: message, isError: isError)
            } catch {
                finish(message: error.localizedDescription, isError: true)
            }
        }
    }

    func checkFlakiness(remote: Bool = false) {
        let targets = lastFailingSuites
        guard !targets.isEmpty else {
            lastMessage = "No failing suites to check. Run the tests first."
            lastMessageIsError = true
            return
        }
        let iterations = store.settings.flakeIterations
        if remote {
            runRemote(.remoteFlakeCheck, mode: .flakeCheck(iterations: iterations), onlyTesting: targets.map(\.identifier))
            return
        }
        guard begin(.flakeCheck), let (ctx, env) = requireEnvironment() else { return }
        let runner = TestRunner(repository: ctx.repository, config: ctx.config, environment: env)
        cancelAction = { runner.cancel() }
        let onLine = onLine, onEvent = onEvent
        Task {
            do {
                let result = try await runner.run(onlyTesting: targets.map(\.identifier),
                                                  additionalArguments: Flakiness.arguments(iterations: iterations),
                                                  onLine: onLine, onEvent: onEvent)
                applyFlakeResult(result, iterations: iterations)
            } catch {
                finish(message: error.localizedDescription, isError: true)
            }
        }
    }

    private func applyFlakeResult(_ result: TestRunResult, iterations: Int) {
        RunHistory(repository: project.url).append(RunRecord.make(kind: .flakeCheck, host: result.host, repository: project.url, result: result))
        historyFlaky = RunHistory.flakySignals(RunHistory(repository: project.url).load())
        guard let summary = result.summary else {
            finish(message: result.cancelled ? "Cancelled." : "Flakiness check produced no results.", isError: !result.cancelled)
            return
        }
        flakeResults = Flakiness.classify(summary)
        lastResult = result
        passed = flakeResults.reduce(0) { $0 + $1.passed }
        failed = flakeResults.reduce(0) { $0 + $1.failed }
        failures = failures.map { item in
            var item = item
            item.verdict = flakeResults.first { $0.id == item.id }?.verdict
            return item
        }
        let flaky = flakeResults.filter { $0.verdict == .flaky }.count
        let always = flakeResults.filter { $0.verdict == .alwaysFails }.count
        finish(message: "\(iterations)× on \(result.host): \(always) fail every time, \(flaky) flaky, \(flakeResults.count - always - flaky) pass.")
        tab = .failures
    }

    func runRemote() {
        runRemote(.remoteRun, mode: .run, onlyTesting: nil)
    }

    func reRecordOnRemote() {
        guard !lastFailingSuites.isEmpty else {
            lastMessage = "No failing suites to re-record. Run the tests first."
            lastMessageIsError = true
            return
        }
        runRemote(.remoteRecord, mode: .record(suites: lastFailingSuites), onlyTesting: nil)
    }

    private func runRemote(_ op: RunOperation, mode: RemoteMode, onlyTesting: [String]?) {
        guard begin(op) else { return }
        guard let ctx = context else { finish(message: configError ?? "No configuration.", isError: true); return }
        let transport: RemoteTransport
        do { transport = try ctx.config.remoteTransport() } catch { finish(message: error.localizedDescription, isError: true); return }
        let runner = RemoteRunner(repository: ctx.repository, config: ctx.config, transport: transport)
        cancelAction = { runner.cancel() }
        let onLine = onLine, onEvent = onEvent
        Task {
            do {
                let out = try await runner.run(
                    mode: mode, onlyTesting: onlyTesting,
                    onStage: { stage in Task { @MainActor in self.stageLabel = "\(transport.label): \(stage.label)" } },
                    onLine: onLine, onEvent: onEvent)
                switch mode {
                case .run:
                    completeRun(out.run, images: out.attachments, kind: .run, attachmentsDirectory: out.attachmentsDirectory)
                case .flakeCheck(let n):
                    applyFlakeResult(out.run, iterations: n)
                case .record:
                    RunHistory(repository: project.url).append(RunRecord.make(kind: .record, host: out.host, repository: project.url, result: out.run))
                    finish(message: out.run.cancelled ? "Cancelled." : "Recorded on \(out.host); downloaded \(out.downloadedSnapshots.count) snapshot(s). Review them in Changes.")
                    if !out.run.cancelled { tab = .changes }
                }
            } catch {
                finish(message: error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: Log

    private func appendLog(_ lines: [String]) {
        log.append(contentsOf: lines)
        if log.count > 8000 { log.removeFirst(log.count - 8000) }
    }

    var visibleLog: [String] {
        showFullLog ? log : log.filter(Self.isInteresting)
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
    var modules: [String] = []
    var detectedBaseBranch: String?
    var currentBranch: String?
    var tab: ProjectTab = .run
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
    var failingSuites: [SuiteResult] = []
    var failures: [FailureItem] = []
    var failureSource: FailureSource?
    var flakeResults: [FlakeResult] = []
    var historyFlaky: [FlakySignal] = []
    var changeSet: SnapshotChangeSet?
    var changeImages: [String: (Data?, Data?)] = [:]
}

extension ProjectModel {
    func apply(_ f: ProjectFixture) {
        context = f.context
        configError = nil
        environment = f.environment
        environmentError = f.environmentError
        modules = f.modules
        detectedBaseBranch = f.detectedBaseBranch ?? f.context?.config.baseBranch
        currentBranch = f.currentBranch
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
        lastResult = f.lastResult
        lastMessage = f.lastMessage
        lastMessageIsError = f.lastMessageIsError
        lastFailingSuites = f.failingSuites
        flakeResults = f.flakeResults
        historyFlaky = f.historyFlaky
        failures = f.failures
        failureSource = f.failureSource
        selectedFailureID = f.failures.first?.id
        changeSet = f.changeSet
        changesError = nil
        isLoadingChanges = false
        fixtureImages = f.changeImages
        selectedChangeID = filteredChanges.first?.id
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.flushNow() }
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
