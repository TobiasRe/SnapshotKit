import Foundation
import SnapshotKitCore

// snapkit — command-line front end to SnapshotKitCore.
// The app and this tool share configuration, last-run state and the patch journal.

let usage = """
usage: snapkit <command> [options]

commands:
  snapshots  [--repo P] [--filter TEXT] [--orphans] [--sort size|recent]
                                                 list every snapshot with its state; totals at the end
  record     [--repo P] TEXT… [--whole-suite] [--no-verify] [--verbose]
                                                 re-record the tests of the snapshots whose path contains every TEXT
  config     [--repo P]                          show resolved configuration and check Xcode/simulator
  run        [--repo P] [--only ID]... [--module M] [--iterations N] [--remote [HOST]] [--verbose]
                                                 run the tests like CI; --module runs one test target only
  rerecord   [--repo P] [--suite ID]... [--no-verify] [--remote [HOST]] [--verbose]
                                                 re-record the failing suites of the last run, or the given
                                                 ones (ID = Bundle/Suite), then verify them where they were recorded
  flaky      [--repo P] [--suite ID]... [--iterations N] [--remote [HOST]] [--verbose]
                                                 run those suites N times; exits 1 if a test is flaky or always fails
  failures   [--repo P] [--xcresult PATH] [--out DIR]   list failures, diagnose each diff, show recent runs
  changes    [--repo P] [--base BRANCH] [--tip] [--filter TEXT]
                                                 snapshot images that differ from the base branch
  history    [--repo P] [TEST]                   recent runs and flaky tests; TEST = Bundle/Suite/test()
  restore    [--repo P] [--force]                undo a leftover record patch; --force even when a running
                                                 SnapshotKit owns it
  diff       A.png B.png [-o OUT.png]             pixel and perceptual difference, with a precision that passes;
                                                 exits 0 when identical, 1 when they differ, 2 on trouble
  open       REFERENCE.png ACTUAL.png [--app PATH]
                                                 the same summary, then compare them in SnapshotKit (the app at
                                                 --app or $SNAPSHOTKIT_APP, else the installed one); to use it as
                                                 the diff tool: https://tobiasre.github.io/SnapshotKit/docs/diff-tool/
  projects   scan ROOT... | list

Every command first restores record patches left behind by an interrupted run.
Options a command doesn't take, and missing or malformed values, exit with 64.
`snapkit --version` prints the version.
"""

/// The options each command takes, and how many other arguments (checked by the command itself
/// where it has its own usage line).
let commands: [String: (options: [String: CommandArguments.Option], positional: ClosedRange<Int>)] = [
    "snapshots": (["--repo": .value, "--filter": .value, "--orphans": .flag, "--sort": .value], 0...0),
    "record": (["--repo": .value, "--whole-suite": .flag, "--no-verify": .flag, "--verbose": .flag], 0...Int.max),
    "config": (["--repo": .value], 0...0),
    "run": (["--repo": .value, "--only": .value, "--module": .value, "--iterations": .value, "--remote": .optionalValue, "--verbose": .flag], 0...0),
    "rerecord": (["--repo": .value, "--suite": .value, "--no-verify": .flag, "--remote": .optionalValue, "--verbose": .flag], 0...0),
    "flaky": (["--repo": .value, "--suite": .value, "--iterations": .value, "--remote": .optionalValue, "--verbose": .flag], 0...0),
    "failures": (["--repo": .value, "--xcresult": .value, "--out": .value], 0...0),
    "changes": (["--repo": .value, "--base": .value, "--tip": .flag, "--filter": .value], 0...0),
    "history": (["--repo": .value], 0...1),
    "restore": (["--repo": .value, "--force": .flag], 0...0),
    "diff": (["-o": .value], 0...Int.max),
    "open": (["--app": .value], 0...Int.max),
    "projects": ([:], 0...Int.max),
]

// MARK: - Output

/// Colour only on a terminal, and never with NO_COLOR set (https://no-color.org).
func usesColor(_ descriptor: Int32) -> Bool {
    isatty(descriptor) != 0 && (ProcessInfo.processInfo.environment["NO_COLOR"] ?? "").isEmpty
}
let stdoutHasColor = usesColor(STDOUT_FILENO)
let stderrHasColor = usesColor(STDERR_FILENO)

func color(_ code: String, _ text: String, onStderr: Bool = false) -> String {
    (onStderr ? stderrHasColor : stdoutHasColor) ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
}

/// ✔ ✘ ◐ per run, oldest first, as on the app's Failures tab.
func historyStrip(_ points: [HistoryPoint]) -> String {
    points.map { p in
        switch p.result {
        case .passed: color("32", "✔")
        case .failed: color("31", "✘")
        case .mixed: color("33", "◐")
        }
    }.joined(separator: " ")
}

func say(_ text: String) { print(text); fflush(stdout) }

/// Notes and warnings: on standard error, so they don't mix with what a command prints.
func warn(_ text: String, color code: String = "33") {
    FileHandle.standardError.write(Data((color(code, text, onStderr: true) + "\n").utf8))
}

func fail(_ text: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((color("31", "error: ", onStderr: true) + text + "\n").utf8))
    exit(code)
}

/// Ends a command whose tests could not run. A Ctrl-C before `xcodebuild` started (while the scheme
/// was looked up, say) throws `CancellationError`: a cancel like any other, not an error. The remote
/// Mac lacking the Xcode or simulator exits 2, as this one does.
func fail(running error: any Error) -> Never {
    if error is CancellationError { exitCancelled() }
    fail(error.localizedDescription, code: error is RemoteEnvironmentError ? 2 : 1)
}

/// Says so and exits 1, as every command that runs tests does when cancelled.
func exitCancelled() -> Never {
    say(color("33", "Cancelled."))
    exit(1)
}

func usageError(_ text: String) -> Never {
    fail(text + "\nRun `snapkit help` for usage.", code: EX_USAGE)
}

/// Prints test-relevant lines only (or everything with --verbose) plus a live counter on TTYs.
final class Printer: Sendable {
    let verbose: Bool
    /// Lines arrive from the runner's threads; one at a time keeps them whole.
    private let lock = NSLock()
    init(verbose: Bool) { self.verbose = verbose }

    func line(_ raw: String) {
        let line = TestOutputParser.withoutInvisiblePrefix(raw)
        lock.withLock {
            if verbose || line.hasPrefix("$ ") || line.hasPrefix("snapkit:") || line.hasPrefix("◇ Suite") || line.hasPrefix("✘")
                || line.hasPrefix("✔ Test run") || line.hasPrefix("** ") || line.contains(": error: ")
                || line.hasPrefix("Test case '") && line.contains("failed") || line.hasPrefix("↳ ") && !line.contains("Testing Library") && !line.contains("Target Platform") {
                say(String(line))
            }
        }
    }

    func event(_ event: TestEvent, _ parser: TestOutputParser) {
        lock.withLock {
            // "Building…", but "Testing" (the tests' own lines follow) and "Finished".
            if case .phase(let phase) = event { say(color("36", "▸ \(phase.label)") + (phase < .testing ? "…" : "")) }
        }
    }
}

// MARK: - Ctrl-C

/// What the first Ctrl-C does: cancel the running command, which then still prints its summary
/// and records the run. A second Ctrl-C, or one with nothing to cancel, restores record patches
/// and quits. (Variables at the top level of main.swift belong to the main actor.)
var cancelOnInterrupt: (() -> Void)?
var interruptSource: DispatchSourceSignal?

/// SIGINT is handled here and not by InterruptGuard (installed with `interrupt: false`): every
/// source for a signal runs, and InterruptGuard's would exit before the cancelled run is recorded.
@MainActor func handleInterrupts() {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated {
            if let cancel = cancelOnInterrupt {
                cancelOnInterrupt = nil
                warn("\nInterrupted — cancelling (press Ctrl-C again to force quit)…")
                cancel()
            } else {
                for report in InterruptGuard.restoreAll() where !report.files.isEmpty { warn("snapkit: " + report.summary) }
                exit(130)
            }
        }
    }
    source.resume()
    interruptSource = source
}

@MainActor func onInterrupt(_ cancel: @escaping () -> Void) { cancelOnInterrupt = cancel }

// MARK: - Helpers

func repository(_ o: CommandArguments) -> URL {
    let path = o.value("--repo") ?? FileManager.default.currentDirectoryPath
    guard FileManager.default.fileExists(atPath: path) else { fail("no such folder: \(path)") }
    do {
        guard let git = try Git.repository(at: URL(fileURLWithPath: path)) else { fail("\(path) is not inside a git repository") }
        return git.root
    } catch {
        fail(error.localizedDescription)
    }
}

func context(_ o: CommandArguments) -> ProjectContext {
    let repo = repository(o)
    let store = ProjectStore()
    var settings = store.settings(for: Project(path: repo.path))
    if let module = o.value("--module") { settings.module = module }
    if let remote = o.value("--remote") { settings.remoteHost = remote }
    do {
        return try ProjectContext.load(repository: repo, settings: settings)
    } catch {
        fail(error.localizedDescription)
    }
}

func iterations(_ o: CommandArguments) -> Int? {
    do { return try o.integer("--iterations", atLeast: Flakiness.minimumIterations) } catch { usageError(error.description) }
}

func environment(_ config: SnapshotConfig) -> TestEnvironment {
    do {
        let env = try EnvironmentValidator.validate(config)
        say("snapkit: Xcode \(env.xcode.version)\(env.xcodeIsDefault ? " (not pinned by CI; using selected)" : "") · \(env.simulator.name) \(env.simulator.platform) \(env.simulator.osVersion)")
        for note in env.notes { warn("note: " + note) }
        return env
    } catch {
        fail(error.localizedDescription, code: 2)
    }
}

func remoteRunner(_ ctx: ProjectContext) -> RemoteRunner {
    do {
        return RemoteRunner(repository: ctx.repository, config: ctx.config, transport: try ctx.config.remoteTransport())
    } catch {
        fail(error.localizedDescription)
    }
}

func printSummary(_ result: TestRunResult) {
    if result.cancelled { say(color("33", "Cancelled.")) }
    let failed = result.failed > 0 ? color("31", "\(result.failed) failed") : "0 failed"
    say("\nResult: \(color("32", "\(result.passed) passed")), \(failed), \(result.skipped) skipped  [\(result.host)]")
    if !result.buildErrors.isEmpty {
        say(color("31", "Build errors:"))
        for e in result.buildErrors.prefix(10) { say("  \(e)") }
    }
    for suite in result.failingSuites {
        say(color("31", "FAILING SUITE: \(suite.identifier)") + " (\(suite.failedCount)/\(suite.tests.count) tests)")
        for test in suite.tests where test.outcome == .failed { say("  ✘ \(test.name)") }
    }
    say("Result bundle: \(result.resultBundle.path)")
}

func record(_ result: TestRunResult, kind: RunKind, repo: URL, attachments: URL? = nil) {
    RunHistory(repository: repo).append(RunRecord.make(kind: kind, host: result.host, repository: repo, result: result))
    switch kind {
    case .run: LastRun.update(with: result, attachmentsDirectory: attachments, repository: repo)
    // Ran only the re-recorded tests: the last run's other results stay.
    case .verify: LastRun.update(with: result, partial: true, attachmentsDirectory: attachments, repository: repo)
    case .record, .flakeCheck, .imported: break
    }
}

/// A record run that was cancelled, or whose tests never ran (say, the build failed), recorded
/// nothing to report: says so and exits 1.
func exitUnlessRecorded(_ run: TestRunResult) {
    if run.cancelled { exitCancelled() }
    if let why = run.nothingTested { fail("Nothing was recorded: \(why).") }
}

/// A verification that was cancelled, or never started because of a Ctrl-C after recording, says
/// so instead of reporting a result, and exits 1.
func exitIfCancelled(verification run: TestRunResult?, requested: Bool = true) {
    guard requested, run?.cancelled ?? true else { return }
    say(color("33", "Recorded; the verification was cancelled."))
    exit(1)
}

/// Exports a local run's failure images next to its bundle: them, and their folder when there are any.
func exportAttachments(of result: TestRunResult, environment: TestEnvironment) -> ([SnapshotFailureImages], URL?) {
    let dir = result.resultBundle.deletingPathExtension().appendingPathExtension("attachments")
    let attachments = (try? FailureAttachments.export(resultBundle: result.resultBundle, to: dir,
                                                      developerDir: environment.xcode.developerDir)) ?? []
    return (attachments, attachments.isEmpty ? nil : dir)
}

func warnAboutConflicts(_ report: RestoreReport) {
    for conflict in report.conflicts {
        warn("WARNING: \(conflict.path) could not be restored; original at \(conflict.backup)", color: "31")
    }
}

/// Runs locally or remotely, wiring Ctrl-C to cancellation.
@MainActor
func runTests(_ ctx: ProjectContext, remote: Bool, onlyTesting: [String]?, iterations: Int?, printer: Printer) async -> (TestRunResult, [SnapshotFailureImages], URL?) {
    let config = ctx.config
    if remote {
        let runner = remoteRunner(ctx)
        onInterrupt { runner.cancel() }
        do {
            let out = try await runner.run(mode: iterations.map { .flakeCheck(iterations: $0) } ?? .run, onlyTesting: onlyTesting,
                                           onStage: { say(color("36", "▸ \($0.label)")) }, onLine: { printer.line($0) }, onEvent: { printer.event($0, $1) })
            return (out.run, out.attachments, out.attachmentsDirectory)
        } catch { fail(running: error) }
    }
    let runner = TestRunner(repository: ctx.repository, config: config, environment: environment(config))
    onInterrupt { runner.cancel() }
    do {
        let result = try await runner.run(onlyTesting: onlyTesting,
                                          additionalArguments: iterations.map(Flakiness.arguments) ?? [],
                                          onLine: { printer.line($0) }, onEvent: { printer.event($0, $1) })
        let (attachments, dir) = exportAttachments(of: result, environment: runner.environment)
        return (result, attachments, dir)
    } catch { fail(running: error) }
}

/// The suites `--suite` names, else the failing suites of the last run, else those of a new run,
/// where the command runs (with `--remote`, on the remote Mac).
@MainActor
func failingSuites(_ ctx: ProjectContext, o: CommandArguments, printer: Printer) async -> [SuiteResult] {
    let last = LastRun.load(repository: ctx.repository)
    let requested = o.all("--suite")
    if !requested.isEmpty {
        // The last run's own entries know the suites' source files.
        let known = last?.suites ?? last?.failingSuites ?? []
        return requested.map { id in
            if let suite = known.first(where: { $0.identifier == id || $0.name == id }) { return suite }
            let parts = id.split(separator: "/").map(String.init)
            guard parts.count > 1 else { usageError("--suite \(id): name its test target too, as in --suite AppTests/\(id)") }
            return SuiteResult(bundle: parts[0], path: Array(parts.dropFirst()), tests: [], failureFiles: [])
        }
    }
    // A last run without failures leaves nothing to do; only without one are the tests run first.
    if let last {
        if !last.failingSuites.isEmpty {
            say("snapkit: using failing suites from the last run (\(last.host), \(last.date.formatted(date: .omitted, time: .shortened)))")
        }
        return last.failingSuites
    }
    say("snapkit: no previous run recorded; running tests to find failing suites")
    let (result, _, dir) = await runTests(ctx, remote: o.has("--remote"), onlyTesting: nil, iterations: nil, printer: printer)
    record(result, kind: .run, repo: ctx.repository, attachments: dir)
    printSummary(result)
    // The summary says "Cancelled." or shows the build errors; the run found out nothing to go on with.
    if result.cancelled { exit(1) }
    if let why = result.nothingTested { fail("Could not find the failing suites: \(why).") }
    return result.failingSuites
}

/// Takes a re-record's verification run into the last run, and exits with its outcome.
func finishVerification(_ verify: TestRunResult, repo: URL, attachments: URL? = nil) -> Never {
    record(verify, kind: .verify, repo: repo, attachments: attachments)
    exitIfCancelled(verification: verify)
    if let why = verify.nothingTested { fail("Could not verify: \(why).") }
    say(verify.succeeded ? color("32", "Verified: \(verify.passed) passed with the new references.")
                         : color("31", "Verification failed: \(verify.failed) still failing (flaky?). Try `snapkit flaky`."))
    exit(verify.succeeded ? 0 : 1)
}

/// The image at `path`, or an error saying why it can't be read.
func readImage(_ path: String) throws -> PixelImage {
    struct NotAnImage: LocalizedError {
        var path: String
        var errorDescription: String? { "\(path) is not an image" }
    }
    guard let image = PixelImage(data: try Data(contentsOf: URL(fileURLWithPath: path))) else { throw NotAnImage(path: path) }
    return image
}

/// Prints how two images differ, and which precision would pass.
@discardableResult
func describeDiff(_ a: PixelImage, _ b: PixelImage) -> ImageDiffResult {
    let diff = ImageDiff.compare(a, b)
    say(diff.isIdentical ? "identical" : String(format: "%d pixels differ (%.3f%%)%@, largest ΔE %.1f", diff.changedPixels, diff.changedFraction * 100,
                                                diff.sizeChanged ? ", size changed" : "", diff.maxPerceptualDelta))
    let diagnosis = DiffDiagnosis(diff)
    if !diff.isIdentical { say(diagnosis.summary) }
    if let suggestion = diagnosis.suggestion { say("Would pass with: \(suggestion)") }
    return diff
}

// MARK: - Commands

@MainActor
func main() async {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.isEmpty ? "" : arguments.removeFirst()
    InterruptGuard.install(interrupt: false) { report in warn("snapkit: " + report.summary) }
    handleInterrupts()
    let leftovers = RecordSession.restoreAllLeftovers()
    for report in leftovers.reports where !report.files.isEmpty {
        warn("snapkit: restored leftover record patch in \(report.repository.path):\n  " + report.summary.replacingOccurrences(of: "\n", with: "\n  "))
    }
    for failure in leftovers.failures {
        warn("snapkit: could not restore the record patch in \(failure.repository.path): \(failure.error.localizedDescription)", color: "31")
    }

    switch command {
    case "", "help", "-h", "--help":
        say(usage)
        exit(0)
    case "version", "--version", "-v":
        say("snapkit \(SnapshotKitVersion.current)")
        exit(0)
    default:
        break
    }
    guard let spec = commands[command] else { usageError("unknown command '\(command)'") }
    let o: CommandArguments
    do { o = try CommandArguments(arguments, options: spec.options, positional: spec.positional) } catch { usageError("snapkit \(command): \(error)") }
    let printer = Printer(verbose: o.has("--verbose"))

    switch command {
    case "config":
        let ctx = context(o)
        let c = ctx.config
        func row(_ name: String, _ value: String?, _ field: SnapshotConfig.Field) {
            say("  \(name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(value ?? "—")" + (c.source(of: field).map { color("90", "  (\($0))") } ?? ""))
        }
        /// A row for a value that is rarely set, only when it is.
        func rowIfSet(_ name: String, _ value: String?, _ field: SnapshotConfig.Field) {
            if value?.isEmpty == false || c.source(of: field) != nil { row(name, value, field) }
        }
        say("Repository: \(ctx.repository.path)")
        say("CI files:   \(ctx.resolved.ciFiles.isEmpty ? "none" : ctx.resolved.ciFiles.joined(separator: ", "))")
        say("Override:   \(ctx.resolved.overrideFile ?? "none")")
        row("xcode", c.xcodeVersion, .xcodeVersion)
        rowIfSet("developerDir", c.developerDir, .developerDir)
        rowIfSet("platform", c.platform, .platform)
        row("device", c.deviceName, .deviceName)
        row("os", c.osVersion, .osVersion)
        row("scheme", c.scheme, .scheme)
        row("workspace", c.workspace, .workspace)
        row("project", c.project, .project)
        row("testPlan", c.testPlan, .testPlan)
        row("onlyTesting", c.onlyTesting.isEmpty ? nil : c.onlyTesting.joined(separator: ", "), .onlyTesting)
        rowIfSet("skipTesting", c.skipTesting.joined(separator: ", "), .skipTesting)
        rowIfSet("extraArgs", c.extraArguments.map(Shell.quote).joined(separator: " "), .extraArguments)
        row("baseBranch", c.baseBranch, .baseBranch)
        row("workingDir", c.workingDirectory, .workingDirectory)
        row("remoteHost", c.remoteHost, .remoteHost)
        rowIfSet("remoteDir", c.remoteDirectory, .remoteDirectory)
        let modules = ctx.modules()
        say("  modules        \(modules.isEmpty ? "—" : modules.joined(separator: ", "))")
        for note in ctx.resolved.notes { say(color("33", "note: ") + note) }
        let env = environment(c)
        say("Xcode used: \(env.xcode.path)")

    case "run":
        let ctx = context(o)
        let iterations = iterations(o)
        let only = o.all("--only")
        let (result, attachments, attachmentsDir) = await runTests(ctx, remote: o.has("--remote"), onlyTesting: only.isEmpty ? nil : only, iterations: iterations, printer: printer)
        record(result, kind: iterations == nil ? .run : .flakeCheck, repo: ctx.repository, attachments: attachmentsDir)
        printSummary(result)
        if !attachments.isEmpty { say("Failure images: \(attachments.count) (see `snapkit failures`)") }
        exit(result.succeeded ? 0 : 1)

    case "snapshots":
        let repo = repository(o)
        let library: SnapshotLibrary
        do { library = try SnapshotLibrary.load(repository: repo) } catch { fail(error.localizedDescription) }
        var files = SnapshotLibrary.filter(library.files, text: o.value("--filter") ?? "")
        let orphans = SnapshotLibrary.orphans(library.files, repository: repo)
        if o.has("--orphans") { files = files.filter { orphans.contains($0.id) } }
        switch o.value("--sort") {
        case nil: break
        case "size": files.sort { $0.byteSize > $1.byteSize }
        case "recent": files.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case let other?: usageError("--sort takes size or recent, not '\(other)'")
        }
        for file in files {
            let size = SnapshotLibrary.formatSize(file.byteSize)
            var marks: [String] = []
            if file.state == .modified { marks.append(color("33", "modified")) }
            if file.state == .untracked { marks.append(color("32", "new")) }
            if orphans.contains(file.id) { marks.append(color("90", "orphaned")) }
            say("\(file.path)  \(size)" + (marks.isEmpty ? "" : "  " + marks.joined(separator: " ")))
        }
        let total = SnapshotLibrary.formatSize(files.reduce(0) { $0 + $1.byteSize })
        let tests = Set(files.map { $0.module + "/" + $0.suite + "/" + $0.testName }).count
        say("\(files.count) of \(library.files.count) snapshots · \(tests) test\(tests == 1 ? "" : "s") · \(total)"
            + (orphans.isEmpty ? "" : " · \(orphans.count) orphaned (`--orphans` lists them)"))

    case "record":
        guard !o.positional.isEmpty else { usageError("usage: snapkit record TEXT… (part of a snapshot path, e.g. a test or suite name)") }
        let ctx = context(o)
        let library: SnapshotLibrary
        do { library = try SnapshotLibrary.load(repository: ctx.repository) } catch { fail(error.localizedDescription) }
        let orphans = SnapshotLibrary.orphans(library.files, repository: ctx.repository)
        let files = SnapshotLibrary.filter(library.files, text: o.positional.joined(separator: " ")).filter { !orphans.contains($0.id) }
        guard !files.isEmpty else { fail("No snapshot path contains \(o.positional.map { "“\($0)”" }.joined(separator: " and ")).") }
        let selection: RecordSelection
        do {
            selection = try RecordPlanner.plan(files, granularity: o.has("--whole-suite") ? .suites : .tests, repository: ctx.repository)
        } catch { fail(error.localizedDescription) }
        say("snapkit: recording \(selection.onlyTesting.joined(separator: ", "))")
        let recorder = ReRecorder(runner: TestRunner(repository: ctx.repository, config: ctx.config, environment: environment(ctx.config)))
        onInterrupt { recorder.cancel() }
        do {
            let outcome = try await recorder.reRecord(suites: selection.suites, onlyTesting: selection.onlyTesting, verify: !o.has("--no-verify"),
                                                      onStage: { say(color("36", "▸ \($0.label)")) },
                                                      onLine: { printer.line($0) }, onEvent: { printer.event($0, $1) })
            record(outcome.recordRun, kind: .record, repo: ctx.repository)
            warnAboutConflicts(outcome.restore)
            exitUnlessRecorded(outcome.recordRun)
            if let verify = outcome.verifyRun {
                // The images of what still fails: the verification's results replace the last run's.
                record(verify, kind: .verify, repo: ctx.repository, attachments: exportAttachments(of: verify, environment: recorder.runner.environment).1)
            }
            exitIfCancelled(verification: outcome.verifyRun, requested: !o.has("--no-verify"))
            if let verify = outcome.verifyRun {
                // A verification whose tests didn't build found out nothing, which isn't "0 still failing".
                if let why = verify.nothingTested { fail("Recorded, but could not verify: \(why).") }
                say(verify.succeeded ? color("32", "Recorded and verified: \(verify.passed) passed.")
                                     : color("31", "Recorded, but verification failed: \(verify.failed) still failing (flaky?)."))
                exit(verify.succeeded ? 0 : 1)
            }
            say("Recorded.")
            exit(0)
        } catch {
            fail(running: error)
        }

    case "rerecord":
        let ctx = context(o)
        let suites = await failingSuites(ctx, o: o, printer: printer)
        guard !suites.isEmpty else { say("Nothing to re-record: no failing suites."); exit(0) }
        say("snapkit: re-recording \(suites.map(\.identifier).joined(separator: ", "))")
        if o.has("--remote") {
            // Recorded and verified on the remote Mac; only the new references come back.
            let runner = remoteRunner(ctx)
            onInterrupt { runner.cancel() }
            var recordedAlready = false
            do {
                let recorded = try await runner.run(mode: .record(suites: suites), onStage: { say(color("36", "▸ \($0.label)")) },
                                                    onLine: { printer.line($0) }, onEvent: { printer.event($0, $1) })
                record(recorded.run, kind: .record, repo: ctx.repository)
                exitUnlessRecorded(recorded.run)
                recordedAlready = true
                say("\nRecorded suites: \(suites.map(\.identifier).joined(separator: ", "))")
                let count = recorded.downloadedSnapshots.count
                say("Downloaded \(count) snapshot\(count == 1 ? "" : "s") recorded on \(recorded.host).")
                if o.has("--no-verify") { exit(0) }
                let verify = try await runner.run(mode: .run, onlyTesting: suites.flatMap(\.onlyTestingIdentifiers), onStage: { say(color("36", "▸ \($0.label)")) },
                                                  onLine: { printer.line($0) }, onEvent: { printer.event($0, $1) })
                finishVerification(verify.run, repo: ctx.repository, attachments: verify.attachmentsDirectory)
            } catch {
                // A Ctrl-C once recorded keeps the verification from starting.
                if error is CancellationError, recordedAlready { exitIfCancelled(verification: nil) }
                fail(running: error)
            }
        }
        let runner = TestRunner(repository: ctx.repository, config: ctx.config, environment: environment(ctx.config))
        let recorder = ReRecorder(runner: runner)
        onInterrupt { recorder.cancel() }
        do {
            let outcome = try await recorder.reRecord(suites: suites, verify: !o.has("--no-verify"),
                                                      onStage: { say(color("36", "▸ \($0.label)")) },
                                                      onLine: { printer.line($0) }, onEvent: { printer.event($0, $1) })
            record(outcome.recordRun, kind: .record, repo: ctx.repository)
            warnAboutConflicts(outcome.restore)
            exitUnlessRecorded(outcome.recordRun)
            say("\nRecorded suites: \(suites.map(\.identifier).joined(separator: ", "))")
            say("Patched and restored: \(outcome.patchedFiles.joined(separator: ", "))")
            if let verify = outcome.verifyRun {
                finishVerification(verify, repo: ctx.repository, attachments: exportAttachments(of: verify, environment: runner.environment).1)
            }
            exitIfCancelled(verification: nil, requested: !o.has("--no-verify"))
            exit(0)
        } catch {
            fail(running: error)
        }

    case "flaky":
        let ctx = context(o)
        // Checked first: finding the failing suites can mean running every test.
        let requested = iterations(o)
        let suites = await failingSuites(ctx, o: o, printer: printer)
        guard !suites.isEmpty else { say("No failing suites to check."); exit(0) }
        let n = requested ?? ProjectStore().settings.flakeIterations
        say("snapkit: running \(suites.map(\.identifier).joined(separator: ", ")) \(n)×")
        let (result, _, _) = await runTests(ctx, remote: o.has("--remote"), onlyTesting: suites.flatMap(\.onlyTestingIdentifiers), iterations: n, printer: printer)
        record(result, kind: .flakeCheck, repo: ctx.repository)
        // A cancelled check repeated its tests only partly (its bundle has what ran): no verdicts.
        if result.cancelled { exitCancelled() }
        // No verdicts, which isn't every test passing.
        if let why = result.nothingTested {
            printSummary(result)
            fail("Nothing was checked: \(why).")
        }
        guard let summary = result.summary else { printSummary(result); exit(1) }
        say("")
        let verdicts = Flakiness.classify(summary)
        // As wide as the longest label: padding(toLength:) would cut "Fails on iPhone SE and iPad".
        let width = max(18, verdicts.map(\.label.count).max() ?? 0)
        for r in verdicts {
            let code = r.verdict == .flaky ? "33" : r.verdict == .alwaysFails ? "31" : "32"
            say("\(color(code, r.label.padding(toLength: width, withPad: " ", startingAt: 0))) \(r.passed)✔ \(r.failed)✘  \(r.suite)/\(r.test)")
        }
        exit(verdicts.allSatisfy { $0.verdict == .passes } ? 0 : 1)

    case "failures":
        let ctx = context(o)
        let last = LastRun.load(repository: ctx.repository)
        let out = o.value("--out").map { URL(fileURLWithPath: $0) }
        do {
            let bundle: URL
            let failingSuites: [SuiteResult], images: [SnapshotFailureImages]
            var imported: TestRunSummary?
            if let path = o.value("--xcresult") {
                bundle = URL(fileURLWithPath: path)
                let summary = try XCResultParser.load(resultBundle: bundle, developerDir: nil)
                failingSuites = summary.failingSuites
                images = try FailureAttachments.export(resultBundle: bundle, to: out ?? bundle.deletingPathExtension().appendingPathExtension("attachments"),
                                                       developerDir: nil)
                imported = summary
            } else if let last, let path = last.resultBundle, path.hasSuffix(".xcresult"), FileManager.default.fileExists(atPath: path) {
                bundle = URL(fileURLWithPath: path)
                // The last run's failures rather than its bundle's: a re-record's verification since may
                // have fixed some, and has the images of those it ran.
                failingSuites = last.failingSuites
                if let out { _ = try FailureAttachments.export(resultBundle: bundle, to: out, developerDir: nil) }
                images = last.failureImages(ownImagesIn: out)
            } else if let last, last.host != "local" {
                // A remote run's bundle stayed on its Mac; its failures and their images came back.
                guard out == nil else {
                    fail("--out exports a result bundle, and the last run’s stayed on \(last.host). Leave out --out to list the images "
                         + "downloaded from there, or pass --xcresult PATH.")
                }
                bundle = URL(fileURLWithPath: last.resultBundle ?? last.host)
                failingSuites = last.failingSuites
                images = last.failureImages()
            } else if let last, let path = last.resultBundle {
                fail("The last run’s results are gone (\(path)). Run the tests again (`snapkit run`), or pass --xcresult PATH.")
            } else {
                fail("No local result bundle. Pass --xcresult PATH (e.g. a CI artifact).")
            }
            for suite in failingSuites {
                say(color("31", suite.identifier))
                for test in suite.tests where test.outcome == .failed {
                    say("  ✘ \(test.name)  (\(test.failedRepetitions)/\(test.repetitions.count) repetitions failed)")
                    // Every reference once: repetitions and devices repeat them, a parameterized test's cases don't.
                    var references: [String] = []
                    for path in test.failureMessages.flatMap({ FailureAttachments.referencePaths(in: $0, repository: ctx.repository) })
                    where !references.contains(path) {
                        references.append(path)
                        say("    reference: \(path)")
                    }
                    let shown = images.filter { $0.belong(to: test, in: suite) && $0.repetition == 1 }
                    let severalDevices = Set(shown.map(\.deviceID)).count > 1, severalCases = Set(shown.map(\.arguments)).count > 1
                    for img in shown {
                        // Say whose images these are: which device, which case of a parameterized test.
                        let owner = [severalDevices ? img.device : nil, severalCases ? img.arguments?.joined(separator: ", ") : nil].compactMap { $0 }
                        if !owner.isEmpty { say("    " + owner.joined(separator: " · ") + ":") }
                        say("    failure:    \(img.failure?.path ?? "—")\n    difference: \(img.difference?.path ?? "—")")
                        if let ref = img.reference.flatMap({ try? readImage($0.path) }), let act = img.failure.flatMap({ try? readImage($0.path) }) {
                            let diagnosis = DiffDiagnosis(ImageDiff.compare(ref, act))
                            say("    " + diagnosis.summary + (diagnosis.suggestion.map { " Would pass with \($0)." } ?? ""))
                        }
                    }
                    let timeline = RunHistory.timeline(for: suite.onlyTestingIdentifier(of: test), in: RunHistory(repository: ctx.repository).load())
                    if timeline.count > 1 { say("    recent runs: " + historyStrip(timeline)) }
                }
            }
            if failingSuites.isEmpty { say("No failing tests in \(bundle.lastPathComponent).") }
            if let summary = imported {
                RunHistory(repository: ctx.repository).append(RunRecord(kind: .imported, host: bundle.lastPathComponent, commit: nil, branch: nil, dirty: false,
                                                                        summary: summary, passed: summary.passed, failed: summary.failed, skipped: summary.skipped,
                                                                        resultBundle: bundle.path))
            }
        } catch { fail(error.localizedDescription) }

    case "changes":
        let ctx = context(o)
        guard let base = o.value("--base") ?? ctx.baseBranch else { fail("No base branch; pass --base BRANCH") }
        do {
            let set = try Git(root: ctx.repository).snapshotChanges(baseBranch: base, against: o.has("--tip") ? .tip : .mergeBase)
            let filtered = SnapshotChangeSet.filter(set.changes, text: o.value("--filter") ?? "")
            say("Snapshots changed vs \(set.baseRef) (\(set.diffBase.label) \(set.baseCommit.prefix(8))): \(filtered.count)")
            for group in SnapshotChangeSet.group(filtered) {
                say(color("1", group.suite))
                for c in group.changes { say("  \(c.kind.label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(c.path)") }
            }
        } catch { fail(error.localizedDescription) }

    case "history":
        let ctx = context(o)
        let records = RunHistory(repository: ctx.repository).load()
        for r in records.suffix(15) {
            say("\(r.date.formatted(date: .numeric, time: .shortened))  \(r.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(r.host.padding(toLength: 12, withPad: " ", startingAt: 0)) \(r.passed)✔ \(r.failed)✘  \(r.commit?.prefix(8) ?? "")\(r.dirty ? "+dirty" : "")")
        }
        let flaky = RunHistory.flakySignals(records)
        say(flaky.isEmpty ? "No flaky signals." : color("33", "Flaky (passed and failed on the same commit):"))
        for f in flaky {
            say("  \(f.test)  \(f.passes)✔ \(f.failures)✘  failing on: \(f.failingHosts.joined(separator: ", "))")
            say("    " + historyStrip(RunHistory.timeline(for: f.test, in: records)))
        }
        if let test = o.positional.first {
            let timeline = RunHistory.timeline(for: test, in: records, limit: 30)
            say(timeline.isEmpty ? "No runs of \(test) recorded." : "\(test): " + historyStrip(timeline))
            for p in timeline {
                say("  \(p.date.formatted(date: .numeric, time: .shortened))  \(p.result)  \(p.kind.rawValue)  \(p.host)  \(p.commit?.prefix(8) ?? "")")
            }
        }

    case "restore":
        let repo = repository(o)
        do {
            if let report = try RecordSession.restoreLeftover(repository: repo, force: o.has("--force")) { say(report.summary) } else { say("No record patch to restore.") }
        } catch { fail(error.localizedDescription) }

    case "diff":
        // Explains what kind of difference it is and which precision would pass. Like diff(1):
        // 0 identical, 1 different, 2 trouble.
        guard o.positional.count == 2 else { usageError("usage: snapkit diff A.png B.png [-o OUT.png]") }
        let diff: ImageDiffResult
        do { diff = describeDiff(try readImage(o.positional[0]), try readImage(o.positional[1])) } catch { fail(error.localizedDescription, code: 2) }
        if let out = o.value("-o") {
            guard let png = diff.image.pngData() else { fail("could not encode the difference image", code: 2) }
            do { try png.write(to: URL(fileURLWithPath: out)) } catch { fail(error.localizedDescription, code: 2) }
        }
        exit(diff.isIdentical ? 0 : 1)

    case "open":
        // swift-snapshot-testing's diff tool: it appends the reference and the actual image's paths,
        // so the failure message ends in a command that opens the pair in SnapshotKit.
        guard o.positional.count == 2 else { usageError("usage: snapkit open REFERENCE.png ACTUAL.png [--app PATH]") }
        let request = CompareRequest(reference: URL(fileURLWithPath: o.positional[0]), actual: URL(fileURLWithPath: o.positional[1]))
        for url in [request.reference, request.actual] where !FileManager.default.fileExists(atPath: url.path) {
            fail("no such file: \(url.path)")
        }
        if let reference = try? readImage(request.reference.path), let actual = try? readImage(request.actual.path) {
            describeDiff(reference, actual)
        }
        let app = o.value("--app") ?? ProcessInfo.processInfo.environment["SNAPSHOTKIT_APP"]
        let opened = try? Shell.run(["open"] + (app.map { ["-a", $0] } ?? ["-b", "org.snapshotkit.SnapshotKit"]) + [request.url.absoluteString])
        guard opened?.succeeded == true else {
            fail("Couldn’t open SnapshotKit\(app.map { " at \($0)" } ?? ""). Install SnapshotKit.app from "
                 + "https://github.com/TobiasRe/SnapshotKit/releases, or pass --app PATH.")
        }

    case "projects":
        let store = ProjectStore()
        switch o.positional.first {
        case "scan":
            let roots = o.positional.dropFirst()
            guard !roots.isEmpty else { usageError("usage: snapkit projects scan ROOT...") }
            // A mistyped folder isn't one macOS won't let us read, nor a scan folder to keep.
            for root in roots where !FileManager.default.fileExists(atPath: root) { fail("no such folder: \(root)") }
            for root in roots { store.addScanRoot(root) }
            let reports = store.rescanReports()
            for report in reports where !report.readable {
                say("Can’t read \(report.root.path): allow access in System Settings › Privacy & Security › Files and Folders.")
            }
            // A project removed from the list stays off it, as in the app.
            let found = reports.flatMap(\.projects)
            let listed = found.filter { !store.settings.removed.contains($0.path) }
            for p in listed { say(p.path) }
            say("\(listed.count) project(s) with snapshot tests (looked \(ProjectScanner.defaultDepth) folders deep).")
            if listed.count < found.count {
                say("Left out \(found.count - listed.count) removed from the list: opening one in SnapshotKit adds it back.")
            }
        case nil, "list":
            guard o.positional.count <= 1 else { usageError("usage: snapkit projects scan ROOT... | list") }
            for p in store.allProjects { say((store.isPinned(p) ? "📌 " : "   ") + p.path) }
        default:
            usageError("usage: snapkit projects scan ROOT... | list")
        }

    default:
        preconditionFailure("\(command) is in `commands` but has no case here")
    }
    exit(0)
}

await main()
