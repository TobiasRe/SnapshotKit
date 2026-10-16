import Foundation
import SnapshotKitCore

// snapkit — command-line front end to SnapshotKitCore.
// The app and this tool share configuration, last-run state and the patch journal.

let usage = """
usage: snapkit <command> [options]

commands:
  snapshots  [--repo P] [--filter TEXT] [--orphans] [--sort size|recent]
                                                 list every snapshot with its state; totals at the end
  record     [--repo P] TEXT… [--whole-suite] [--no-verify]
                                                 re-record the tests of the snapshots whose path contains every TEXT
  config     [--repo P]                          show resolved configuration and check Xcode/simulator
  run        [--repo P] [--only ID]... [--module M] [--iterations N] [--remote [HOST]] [--verbose]
  rerecord   [--repo P] [--suite ID]... [--no-verify] [--remote [HOST]] [--verbose]
                                                 re-record the failing suites of the last run
  flaky      [--repo P] [--iterations N] [--remote [HOST]] [--verbose]
  failures   [--repo P] [--xcresult PATH] [--out DIR]   list failures, diagnose each diff, show recent runs
  changes    [--repo P] [--base BRANCH] [--tip] [--filter TEXT]
  history    [--repo P] [TEST]                   recent runs and flaky tests; TEST = Bundle/Suite/test()
  restore    [--repo P]                          undo a leftover record patch
  diff       A.png B.png [-o OUT.png]             pixel and perceptual difference, with a precision that passes
  projects   scan ROOT... | list

Every command first restores record patches left behind by an interrupted run.
`snapkit --version` prints the version.
"""

// MARK: - Argument parsing

struct Options {
    var command = ""
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    func value(_ name: String) -> String? { values[name]?.last }
    func all(_ name: String) -> [String] { values[name] ?? [] }
    func has(_ name: String) -> Bool { flags.contains(name) || values[name] != nil }
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var rest = args[...]
    o.command = rest.popFirst() ?? ""
    let takesValue: Set<String> = ["--repo", "--only", "--module", "--iterations", "--suite", "--xcresult", "--out", "--base", "--filter", "--sort", "-o"]
    let optionalValue: Set<String> = ["--remote"]
    while let arg = rest.popFirst() {
        if takesValue.contains(arg), let v = rest.popFirst() {
            o.values[arg, default: []].append(v)
        } else if optionalValue.contains(arg) {
            if let next = rest.first, !next.hasPrefix("-") { o.values[arg, default: []].append(rest.removeFirst()) } else { o.flags.insert(arg) }
        } else if arg.hasPrefix("-") {
            o.flags.insert(arg)
        } else {
            o.positional.append(arg)
        }
    }
    return o
}

// MARK: - Output

let isTTY = isatty(STDOUT_FILENO) != 0
func color(_ code: String, _ text: String) -> String { isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
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
func fail(_ text: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((color("31", "error: ") + text + "\n").utf8))
    exit(code)
}

/// Prints test-relevant lines only (or everything with --verbose) plus a live counter on TTYs.
final class Printer: @unchecked Sendable {
    let verbose: Bool
    private let lock = NSLock()
    init(verbose: Bool) { self.verbose = verbose }

    func line(_ line: String) {
        lock.withLock {
            if verbose || line.hasPrefix("$ ") || line.hasPrefix("snapkit:") || line.hasPrefix("◇ Suite") || line.hasPrefix("✘")
                || line.hasPrefix("✔ Test run") || line.hasPrefix("** ") || line.contains(": error: ")
                || line.hasPrefix("Test case '") && line.contains("failed") || line.hasPrefix("↳ ") && !line.contains("Testing Library") && !line.contains("Target Platform") {
                say(line)
            }
        }
    }

    func event(_ event: TestEvent, _ parser: TestOutputParser) {
        lock.withLock {
            if case .phase(let phase) = event { say(color("36", "▸ \(phase.label)") + (phase == .testing ? "" : "…")) }
        }
    }
}

// MARK: - Helpers

func repository(_ o: Options) -> URL {
    let path = o.value("--repo") ?? FileManager.default.currentDirectoryPath
    guard let git = Git.repository(containing: URL(fileURLWithPath: path)) else { fail("\(path) is not inside a git repository") }
    return git.root
}

func context(_ o: Options) -> ProjectContext {
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

func environment(_ config: SnapshotConfig) -> TestEnvironment {
    do {
        let env = try EnvironmentValidator.validate(config)
        say("snapkit: Xcode \(env.xcode.version)\(env.xcodeIsDefault ? " (not pinned by CI; using selected)" : "") · \(env.simulator.name) \(env.simulator.platform) \(env.simulator.osVersion)")
        return env
    } catch {
        fail(error.localizedDescription, code: 2)
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
    if kind == .run { LastRun(result: result, attachmentsDirectory: attachments).save(repository: repo) }
}

/// Runs locally or remotely, wiring Ctrl-C to cancellation.
func runTests(_ ctx: ProjectContext, remote: Bool, onlyTesting: [String]?, iterations: Int?, printer: Printer) async -> (TestRunResult, [SnapshotFailureImages], URL?) {
    let config = ctx.config
    if remote {
        let transport: RemoteTransport
        do { transport = try config.remoteTransport() } catch { fail(error.localizedDescription) }
        let runner = RemoteRunner(repository: ctx.repository, config: config, transport: transport)
        onInterrupt { runner.cancel() }
        do {
            let out = try await runner.run(mode: iterations.map { .flakeCheck(iterations: $0) } ?? .run, onlyTesting: onlyTesting,
                                           onStage: { say(color("36", "▸ \($0.label)")) }, onLine: { printer.line($0) }, onEvent: { printer.event($0, $1) })
            return (out.run, out.attachments, out.attachmentsDirectory)
        } catch { fail(error.localizedDescription) }
    }
    let runner = TestRunner(repository: ctx.repository, config: config, environment: environment(config))
    onInterrupt { runner.cancel() }
    do {
        let result = try await runner.run(onlyTesting: onlyTesting,
                                          additionalArguments: iterations.map(Flakiness.arguments) ?? [],
                                          onLine: { printer.line($0) }, onEvent: { printer.event($0, $1) })
        let dir = result.resultBundle.deletingPathExtension().appendingPathExtension("attachments")
        let attachments = (try? FailureAttachments.export(resultBundle: result.resultBundle, to: dir,
                                                          developerDir: runner.environment.xcode.developerDir)) ?? []
        return (result, attachments, attachments.isEmpty ? nil : dir)
    } catch { fail(error.localizedDescription) }
}

/// SIGINT handling that does not fight InterruptGuard: the first Ctrl-C cancels the run gracefully
/// (InterruptGuard still restores patches if a second signal arrives).
nonisolated(unsafe) var interruptHandler: (() -> Void)?
nonisolated(unsafe) var interruptSource: DispatchSourceSignal?
func onInterrupt(_ handler: @escaping () -> Void) {
    interruptHandler = handler
    guard interruptSource == nil else { return }
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    var count = 0
    source.setEventHandler {
        count += 1
        if count == 1 {
            say(color("33", "\nInterrupted — cancelling (press Ctrl-C again to force quit)…"))
            interruptHandler?()
        } else {
            _ = InterruptGuard.restoreAll()
            exit(130)
        }
    }
    source.resume()
    interruptSource = source
}

func failingSuites(_ ctx: ProjectContext, o: Options, printer: Printer) async -> [SuiteResult] {
    let requested = o.all("--suite")
    if let last = LastRun.load(repository: ctx.repository) {
        if !requested.isEmpty {
            let matched = last.failingSuites.filter { requested.contains($0.identifier) || requested.contains($0.name) }
            if matched.count == requested.count { return matched }
        } else if !last.failingSuites.isEmpty {
            say("snapkit: using failing suites from the last run (\(last.host), \(last.date.formatted(date: .omitted, time: .shortened)))")
            return last.failingSuites
        }
    }
    if !requested.isEmpty {
        return requested.map { id in
            let parts = id.split(separator: "/").map(String.init)
            return SuiteResult(bundle: parts.count > 1 ? parts[0] : "", path: Array(parts.dropFirst(parts.count > 1 ? 1 : 0)), tests: [], failureFiles: [])
        }
    }
    say("snapkit: no previous run recorded; running tests to find failing suites")
    let (result, _, dir) = await runTests(ctx, remote: false, onlyTesting: nil, iterations: nil, printer: printer)
    record(result, kind: .run, repo: ctx.repository, attachments: dir)
    printSummary(result)
    return result.failingSuites
}

// MARK: - Commands

@MainActor
func main() async {
    let o = parse(Array(CommandLine.arguments.dropFirst()))
    InterruptGuard.install { report in FileHandle.standardError.write(Data(("snapkit: " + report.summary + "\n").utf8)) }
    for report in RecordSession.restoreAllLeftovers() where !report.files.isEmpty {
        say(color("33", "snapkit: restored leftover record patch in \(report.repository.path):\n  ") + report.summary.replacingOccurrences(of: "\n", with: "\n  "))
    }
    let printer = Printer(verbose: o.has("--verbose"))

    switch o.command {
    case "config":
        let ctx = context(o)
        let c = ctx.config
        func row(_ name: String, _ value: String?, _ field: SnapshotConfig.Field) {
            say("  \(name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(value ?? "—")" + (c.source(of: field).map { color("90", "  (\($0))") } ?? ""))
        }
        say("Repository: \(ctx.repository.path)")
        say("CI files:   \(ctx.resolved.ciFiles.isEmpty ? "none" : ctx.resolved.ciFiles.joined(separator: ", "))")
        say("Override:   \(ctx.resolved.overrideFile ?? "none")")
        row("xcode", c.xcodeVersion ?? c.developerDir, .xcodeVersion)
        row("device", c.deviceName, .deviceName)
        row("os", c.osVersion, .osVersion)
        row("scheme", c.scheme, .scheme)
        row("workspace", c.workspace, .workspace)
        row("project", c.project, .project)
        row("testPlan", c.testPlan, .testPlan)
        row("onlyTesting", c.onlyTesting.isEmpty ? nil : c.onlyTesting.joined(separator: ", "), .onlyTesting)
        row("baseBranch", c.baseBranch, .baseBranch)
        row("workingDir", c.workingDirectory, .workingDirectory)
        row("remoteHost", c.remoteHost, .remoteHost)
        let modules = ctx.modules()
        say("  modules        \(modules.isEmpty ? "—" : modules.joined(separator: ", "))")
        for note in ctx.resolved.notes { say(color("33", "note: ") + note) }
        _ = environment(c)

    case "run":
        let ctx = context(o)
        let iterations = o.value("--iterations").flatMap(Int.init)
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
        case "size": files.sort { $0.byteSize > $1.byteSize }
        case "recent": files.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        default: break
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
        let ctx = context(o)
        guard !o.positional.isEmpty else { fail("usage: snapkit record TEXT… (part of a snapshot path, e.g. a test or suite name)") }
        let library: SnapshotLibrary
        do { library = try SnapshotLibrary.load(repository: ctx.repository) } catch { fail(error.localizedDescription) }
        let orphans = SnapshotLibrary.orphans(library.files, repository: ctx.repository)
        let files = SnapshotLibrary.filter(library.files, text: o.positional.joined(separator: " ")).filter { !orphans.contains($0.id) }
        guard !files.isEmpty else { fail("No snapshot path contains \(o.positional.map { "'\($0)'" }.joined(separator: " and ")).") }
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
            for conflict in outcome.restore.conflicts { say(color("31", "WARNING: \(conflict.path) could not be restored; original at \(conflict.backup)")) }
            if let verify = outcome.verifyRun {
                record(verify, kind: .verify, repo: ctx.repository)
                say(verify.succeeded ? color("32", "Recorded and verified: \(verify.passed) passed.")
                                     : color("31", "Recorded, but verification failed: \(verify.failed) still failing (flaky?)."))
                exit(verify.succeeded ? 0 : 1)
            }
            say("Recorded.")
            exit(outcome.recordRun.cancelled ? 1 : 0)
        } catch {
            fail(error.localizedDescription)
        }

    case "rerecord":
        let ctx = context(o)
        let suites = await failingSuites(ctx, o: o, printer: printer)
        guard !suites.isEmpty else { say("Nothing to re-record: no failing suites."); exit(0) }
        say("snapkit: re-recording \(suites.map(\.identifier).joined(separator: ", "))")
        if o.has("--remote") {
            let transport: RemoteTransport
            do { transport = try ctx.config.remoteTransport() } catch { fail(error.localizedDescription) }
            let runner = RemoteRunner(repository: ctx.repository, config: ctx.config, transport: transport)
            onInterrupt { runner.cancel() }
            do {
                let out = try await runner.run(mode: .record(suites: suites), onStage: { say(color("36", "▸ \($0.label)")) },
                                               onLine: { printer.line($0) }, onEvent: { printer.event($0, $1) })
                say("Downloaded \(out.downloadedSnapshots.count) snapshot(s) recorded on \(out.host).")
                exit(out.run.cancelled ? 1 : 0)
            } catch { fail(error.localizedDescription) }
        }
        let runner = TestRunner(repository: ctx.repository, config: ctx.config, environment: environment(ctx.config))
        let recorder = ReRecorder(runner: runner)
        onInterrupt { recorder.cancel() }
        do {
            let outcome = try await recorder.reRecord(suites: suites, verify: !o.has("--no-verify"),
                                                      onStage: { say(color("36", "▸ \($0.label)")) },
                                                      onLine: { printer.line($0) }, onEvent: { printer.event($0, $1) })
            record(outcome.recordRun, kind: .record, repo: ctx.repository)
            say("\nRecorded suites: \(suites.map(\.identifier).joined(separator: ", "))")
            say("Patched and restored: \(outcome.patchedFiles.joined(separator: ", "))")
            for conflict in outcome.restore.conflicts { say(color("31", "WARNING: \(conflict.path) could not be restored; original at \(conflict.backup)")) }
            if let verify = outcome.verifyRun {
                record(verify, kind: .verify, repo: ctx.repository)
                LastRun(result: verify).save(repository: ctx.repository)
                say(verify.succeeded ? color("32", "Verified: \(verify.passed) passed with the new references.")
                                     : color("31", "Verification failed: \(verify.failed) still failing (flaky?). Try `snapkit flaky`."))
                exit(verify.succeeded ? 0 : 1)
            }
            exit(outcome.recordRun.cancelled ? 1 : 0)
        } catch {
            fail(error.localizedDescription)
        }

    case "flaky":
        let ctx = context(o)
        let suites = await failingSuites(ctx, o: o, printer: printer)
        guard !suites.isEmpty else { say("No failing suites to check."); exit(0) }
        let n = o.value("--iterations").flatMap(Int.init) ?? ProjectStore().settings.flakeIterations
        say("snapkit: running \(suites.map(\.identifier).joined(separator: ", ")) \(n)×")
        let (result, _, _) = await runTests(ctx, remote: o.has("--remote"), onlyTesting: suites.map(\.identifier), iterations: n, printer: printer)
        record(result, kind: .flakeCheck, repo: ctx.repository)
        guard let summary = result.summary else { printSummary(result); exit(1) }
        say("")
        for r in Flakiness.classify(summary) {
            let label = r.verdict == .flaky ? color("33", r.verdict.label) : r.verdict == .alwaysFails ? color("31", r.verdict.label) : color("32", r.verdict.label)
            say("\(label.padding(toLength: isTTY ? 28 : 18, withPad: " ", startingAt: 0)) \(r.passed)✔ \(r.failed)✘  \(r.suite)/\(r.test)")
        }

    case "failures":
        let ctx = context(o)
        let bundle: URL
        if let path = o.value("--xcresult") { bundle = URL(fileURLWithPath: path) }
        else if let last = LastRun.load(repository: ctx.repository)?.resultBundle, last.hasSuffix(".xcresult"), FileManager.default.fileExists(atPath: last) { bundle = URL(fileURLWithPath: last) }
        else { fail("No local result bundle. Pass --xcresult PATH (e.g. a CI artifact).") }
        let out = o.value("--out").map { URL(fileURLWithPath: $0) } ?? bundle.deletingPathExtension().appendingPathExtension("attachments")
        do {
            let summary = try XCResultParser.load(resultBundle: bundle, developerDir: nil)
            let images = try FailureAttachments.export(resultBundle: bundle, to: out, developerDir: nil)
            for suite in summary.failingSuites {
                say(color("31", suite.identifier))
                for test in suite.tests where test.outcome == .failed {
                    say("  ✘ \(test.name)  (\(test.failedRepetitions)/\(test.repetitions.count) repetitions failed)")
                    for message in test.failureMessages.prefix(1) {
                        for path in FailureAttachments.referencePaths(in: message, repository: ctx.repository) { say("    reference: \(path)") }
                    }
                    for img in images where img.testIdentifier == test.identifier && img.repetition == 1 {
                        say("    failure:    \(img.failure?.path ?? "—")\n    difference: \(img.difference?.path ?? "—")")
                        if let ref = img.reference.flatMap({ FileManager.default.contents(atPath: $0.path) }).flatMap(PixelImage.init(data:)),
                           let act = img.failure.flatMap({ FileManager.default.contents(atPath: $0.path) }).flatMap(PixelImage.init(data:)) {
                            let diagnosis = DiffDiagnosis(ImageDiff.compare(ref, act))
                            say("    " + diagnosis.summary + (diagnosis.suggestion.map { " Would pass with \($0)." } ?? ""))
                        }
                    }
                    let timeline = RunHistory.timeline(for: suite.identifier + "/" + test.name, in: RunHistory(repository: ctx.repository).load())
                    if timeline.count > 1 { say("    recent runs: " + historyStrip(timeline)) }
                }
            }
            if summary.failingSuites.isEmpty { say("No failing tests in \(bundle.lastPathComponent).") }
            RunHistory(repository: ctx.repository).append(RunRecord(kind: .imported, host: bundle.lastPathComponent, commit: nil, branch: nil, dirty: false,
                                                                    summary: summary, passed: summary.passed, failed: summary.failed, skipped: summary.skipped, resultBundle: bundle.path))
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
        // Explains what kind of difference it is and which precision would pass.
        guard o.positional.count == 2,
              let a = FileManager.default.contents(atPath: o.positional[0]).flatMap(PixelImage.init(data:)),
              let b = FileManager.default.contents(atPath: o.positional[1]).flatMap(PixelImage.init(data:)) else { fail("usage: snapkit diff A.png B.png [-o OUT.png]") }
        let diff = ImageDiff.compare(a, b)
        say(diff.isIdentical ? "identical" : String(format: "%d pixels differ (%.3f%%)%@, largest ΔE %.1f", diff.changedPixels, diff.changedFraction * 100,
                                                    diff.sizeChanged ? ", size changed" : "", diff.maxPerceptualDelta))
        let diagnosis = DiffDiagnosis(diff)
        if !diff.isIdentical { say(diagnosis.summary) }
        if let suggestion = diagnosis.suggestion { say("Would pass with: \(suggestion)") }
        if let out = o.value("-o") { try? diff.image.pngData()?.write(to: URL(fileURLWithPath: out)) }
        exit(diff.isIdentical ? 0 : 1)

    case "projects":
        let store = ProjectStore()
        if o.positional.first == "scan" {
            for root in o.positional.dropFirst() { store.addScanRoot(root) }
            let found = store.rescan()
            for p in found { say(p.path) }
            say("\(found.count) project(s) with snapshot tests.")
        } else {
            for p in store.allProjects { say((store.isPinned(p) ? "📌 " : "   ") + p.path) }
        }

    case "", "help", "-h", "--help":
        say(usage)
    case "version", "--version", "-v":
        say("snapkit \(SnapshotKitVersion.current)")
    default:
        fail("unknown command '\(o.command)'\n\n" + usage)
    }
    exit(0)
}

await main()
