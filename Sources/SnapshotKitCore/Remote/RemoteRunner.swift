import Foundation

public enum RemoteMode: Sendable {
    /// Run the configured (or given) tests once.
    case run
    /// Run N iterations to tell flaky from consistently failing tests.
    case flakeCheck(iterations: Int)
    /// Record the given suites on the remote machine and bring the new references back.
    case record(suites: [SuiteResult])
}

public enum RemoteStage: String, Sendable {
    case connecting, syncing, patching, running, collecting, done

    public var label: String {
        switch self {
        case .connecting: "Checking remote Xcode and simulator"
        case .syncing: "Syncing working tree"
        case .patching: "Enabling record mode on remote copy"
        case .running: "Running tests remotely"
        case .collecting: "Collecting results"
        case .done: "Done"
        }
    }
}

public struct RemoteRunResult: Sendable {
    public var host: String
    public var environment: TestEnvironment
    public var remoteDirectory: String
    public var run: TestRunResult
    public var attachments: [SnapshotFailureImages]
    /// Local folder holding the downloaded attachments (with its manifest.json).
    public var attachmentsDirectory: URL?
    /// Repository-relative paths of snapshots recorded remotely and copied into the working tree.
    public var downloadedSnapshots: [String]
}

/// Runs snapshot tests on another Mac (typically a CI runner) with the same configuration:
/// syncs the working tree with rsync, checks Xcode/simulator there, runs `xcodebuild`
/// with streamed output, and copies results back.
///
/// Local files are never patched: in record mode the patched sources are uploaded only
/// to the remote copy.
public final class RemoteRunner: @unchecked Sendable { // `process` and `cancelled` are guarded by `lock`.
    public let repository: URL
    public let config: SnapshotConfig
    public let transport: RemoteTransport

    private let lock = NSLock()
    private var process: StreamingProcess?
    private var cancelled = false

    public init(repository: URL, config: SnapshotConfig, transport: RemoteTransport) {
        self.repository = repository
        self.config = config
        self.transport = transport
    }

    // MARK: Preflight

    public struct RemoteInfo: Sendable {
        public var home: String
        public var xcodes: [XcodeInstall]
        public var selected: XcodeInstall?
    }

    static let preflightScript = #"""
    echo "HOME=$HOME"
    echo "SELECTED=$(xcode-select -p 2>/dev/null)"
    for app in /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app; do
      [ -d "$app/Contents/Developer" ] || continue
      v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/version.plist" 2>/dev/null)
      b=$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$app/Contents/version.plist" 2>/dev/null)
      echo "XCODE=$app|$v|$b"
    done
    """#

    public static func parsePreflight(_ output: String) -> RemoteInfo {
        var home = "", selectedPath = ""
        var xcodes: [XcodeInstall] = []
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("HOME=") { home = String(line.dropFirst(5)) }
            if line.hasPrefix("SELECTED=") { selectedPath = String(line.dropFirst(9)) }
            if line.hasPrefix("XCODE=") {
                let parts = line.dropFirst(6).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2, !parts[1].isEmpty else { continue }
                let path = (parts[0] as NSString).standardizingPath
                if !xcodes.contains(where: { $0.path == path }) {
                    xcodes.append(XcodeInstall(path: path, version: parts[1], build: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil))
                }
            }
        }
        xcodes.sort { EnvironmentValidator.compareVersions($0.version, $1.version) == .orderedDescending }
        let selected = xcodes.first { selectedPath == $0.developerDir || selectedPath.hasPrefix($0.path + "/") }
        return RemoteInfo(home: home, xcodes: xcodes, selected: selected)
    }

    /// Checks the remote machine has the Xcode and simulator CI uses.
    public func preflight() throws -> (TestEnvironment, RemoteInfo) {
        let output: String
        do {
            output = try transport.run(Self.preflightScript)
        } catch RemoteError.commandFailed(let host, _, status: 255, let message) {
            // ssh exits 255 when it can't connect or log in; any other status is the script's.
            throw RemoteError.unreachable(host: host, output: message)
        }
        let info = Self.parsePreflight(output)
        let (xcode, isDefault): (XcodeInstall, Bool)
        do {
            (xcode, isDefault) = try EnvironmentValidator.selectXcode(
                for: config, installed: info.xcodes, selected: info.selected, home: info.home,
                lookup: { path in info.xcodes.first { $0.path == (path as NSString).standardizingPath } }
            )
        } catch let error as EnvironmentError {
            throw RemoteEnvironmentError(host: transport.label, underlying: error)
        }
        let json = try transport.run("DEVELOPER_DIR=\(Shell.quote(xcode.developerDir)) xcrun simctl list devices available -j")
        let sims = try EnvironmentValidator.parseSimulators(Data(json.utf8))
        do {
            let sim = try EnvironmentValidator.selectSimulator(for: config, from: sims, xcode: xcode)
            return (TestEnvironment(xcode: xcode, simulator: sim, xcodeIsDefault: isDefault,
                                    notes: EnvironmentValidator.notes(for: config, xcode: xcode)), info)
        } catch let error as EnvironmentError {
            throw RemoteEnvironmentError(host: transport.label, underlying: error)
        }
    }

    // MARK: Paths

    public func remoteDirectory(home: String) -> String {
        if let dir = config.remoteDirectory, !dir.isEmpty {
            return dir.hasPrefix("~/") ? home + dir.dropFirst(1) : dir
        }
        // rsync hands remote paths to the remote shell, so the default stays clear of anything it would split.
        let name = repository.lastPathComponent.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let hash = String(UInt(bitPattern: repository.standardizedFileURL.path.stableHash), radix: 36)
        return "\(home)/.snapshotkit/workspaces/\(name)-\(hash)"
    }

    // MARK: Sync

    /// Tracked and untracked-but-not-ignored files: exactly what a CI checkout plus local edits contains.
    /// Includes the files of submodules (git otherwise lists a submodule as one entry), though not
    /// their untracked files.
    public func filesToSync() throws -> [String] {
        let git = Git(root: repository)
        let tracked = try git.nulSeparated(["ls-files", "-z", "--cached", "--recurse-submodules"])
        let untracked = try git.nulSeparated(["ls-files", "-z", "--others", "--exclude-standard"])
        return (tracked + untracked).filter {
            FileManager.default.fileExists(atPath: repository.appendingPathComponent($0).path)
        }
    }

    func sync(to dir: String) throws {
        let files = try filesToSync()
        _ = try transport.run("mkdir -p \(Shell.quote(dir))")
        try transport.upload(files: files, from: repository, to: dir)
        // Remove files that no longer exist locally (keeps build caches).
        let cleanup = """
        cd \(Shell.quote(dir)) || exit 1
        want=$(mktemp); have=$(mktemp)
        sort > "$want"
        find . -type f -not -path './.build/*' -not -path './.swiftpm/*' -not -path './.snapshotkit/*' -not -path '*/DerivedData/*' | sed 's|^\\./||' | sort > "$have"
        comm -23 "$have" "$want" | while IFS= read -r f; do rm -f -- "$f"; done
        rm -f "$want" "$have"
        """
        _ = try transport.run(cleanup, input: Data((files.joined(separator: "\n") + "\n").utf8))
    }

    // MARK: Run

    /// Runs the tests on the remote machine: checks its Xcode and simulator, syncs the working tree,
    /// runs `xcodebuild` there with streamed output, and copies the results back (and, in record
    /// mode, the new references into the working tree). Throws `CancellationError` when cancelled
    /// before the tests started.
    public func run(
        mode: RemoteMode,
        onlyTesting: [String]? = nil,
        onStage: @escaping @Sendable (RemoteStage) -> Void = { _ in },
        onLine: @escaping @Sendable (String) -> Void = { _ in },
        onEvent: @escaping @Sendable (TestEvent, TestOutputParser) -> Void = { _, _ in }
    ) async throws -> RemoteRunResult {
        onStage(.connecting)
        let (environment, info) = try await offCooperativePool { try self.preflight() }
        onLine("snapkit: \(transport.label): Xcode \(environment.xcode.version), \(environment.simulator.name) (\(environment.simulator.platform) \(environment.simulator.osVersion))")
        for note in environment.notes { onLine("snapkit: \(transport.label): note: \(note)") }
        try checkCancelled()

        let dir = remoteDirectory(home: info.home)
        onStage(.syncing)
        try await offCooperativePool { try self.sync(to: dir) }
        onLine("snapkit: synced working tree to \(transport.label):\(dir)")
        try checkCancelled()

        guard case .record(let suites) = mode else {
            return try await runTests(mode: mode, onlyTesting: onlyTesting, environment: environment, dir: dir,
                                      onStage: onStage, onLine: onLine, onEvent: onEvent)
        }
        onStage(.patching)
        let patched = try await offCooperativePool { try self.uploadPatchedSources(for: suites, to: dir) }
        // From here on, every way out puts the original sources back on the remote copy.
        do {
            let result = try await runTests(mode: mode, onlyTesting: suites.flatMap(\.onlyTestingIdentifiers), environment: environment, dir: dir,
                                            onStage: onStage, onLine: onLine, onEvent: onEvent)
            await restoreSources(patched, in: dir)
            return result
        } catch {
            await restoreSources(patched, in: dir)
            throw error
        }
    }

    private func runTests(
        mode: RemoteMode, onlyTesting: [String]?, environment: TestEnvironment, dir: String,
        onStage: @escaping @Sendable (RemoteStage) -> Void,
        onLine: @escaping @Sendable (String) -> Void,
        onEvent: @escaping @Sendable (TestEvent, TestOutputParser) -> Void
    ) async throws -> RemoteRunResult {
        let stateDir = dir + "/.snapshotkit"
        var additional: [String] = []
        switch mode {
        case .run:
            break
        case .flakeCheck(let iterations):
            additional = Flakiness.arguments(iterations: iterations)
        case .record:
            // What the run writes after this marker is what was recorded.
            try await offCooperativePool {
                try self.transport.run("mkdir -p \(Shell.quote(stateDir)) && touch \(Shell.quote(stateDir + "/record-marker"))")
            }
        }

        let scheme = try await offCooperativePool { try self.remoteScheme(environment: environment, dir: dir) }
        // Named as a local run's, which a run started within the same second can't have: xcodebuild
        // won't write over a bundle, and the history counts one bundle once. Its images here share it.
        let local = TestRunner.newResultBundleURL(for: repository)
        let bundle = "\(stateDir)/results/\(local.lastPathComponent)"
        let args = TestRunner.arguments(config: config, scheme: scheme, destination: environment.destination,
                                        resultBundlePath: bundle, onlyTesting: onlyTesting, additional: additional)
        let workDir = config.workingDirectory.map { dir + "/" + $0 } ?? dir
        let script = "cd \(Shell.quote(workDir)) && mkdir -p \(Shell.quote(stateDir + "/results")) && "
            + "export DEVELOPER_DIR=\(Shell.quote(environment.xcode.developerDir)) && exec xcodebuild "
            + args.map(Shell.quote).joined(separator: " ")
        let (exe, exeArgs) = transport.command(for: script, interactive: true)
        let process = StreamingProcess(executable: exe, arguments: exeArgs)
        let wasCancelled: Bool = lock.withLock {
            self.process = process
            return cancelled
        }
        if wasCancelled { throw CancellationError() }

        onStage(.running)
        onLine("$ [\(transport.label)] xcodebuild " + args.map(Shell.quote).joined(separator: " "))
        try process.start()
        var parser = TestOutputParser()
        for await line in process.lines {
            onLine(line)
            for event in parser.consume(line) { onEvent(event, parser) }
        }
        let status = await process.waitForExit()
        for event in parser.finish() { onEvent(event, parser) }

        onStage(.collecting)
        let summary = try? await offCooperativePool { try self.collectSummary(bundle: bundle, environment: environment, remoteDir: dir) }
        // Kept with the repository's local runs; the bundle itself stays on the remote machine.
        let attachmentsDir = local.deletingPathExtension().appendingPathExtension("attachments")
        let attachments = (try? await offCooperativePool {
            try self.collectAttachments(bundle: bundle, environment: environment, stateDir: stateDir, into: attachmentsDir)
        }) ?? []
        try? await offCooperativePool { try self.pruneResults(in: stateDir + "/results") }
        let run = TestRunResult(
            commandLine: "[\(transport.label)] " + process.commandLine,
            exitStatus: status,
            cancelled: process.isCancelled,
            resultBundle: URL(fileURLWithPath: bundle),
            summary: summary,
            passed: summary?.passed ?? parser.passed,
            failed: summary?.failed ?? parser.failed,
            skipped: summary?.skipped ?? parser.skipped,
            buildErrors: parser.buildErrors,
            host: transport.label
        )
        // A record whose tests never ran (its build failed) recorded nothing, whatever it wrote.
        var downloaded: [String] = []
        if case .record = mode, !run.cancelled, run.nothingTested == nil {
            downloaded = try await offCooperativePool { try self.downloadRecordedSnapshots(dir: dir, stateDir: stateDir) }
            for path in downloaded { onLine("snapkit: downloaded \(path)") }
        }
        onStage(.done)
        return RemoteRunResult(host: transport.label, environment: environment, remoteDirectory: dir,
                               run: run, attachments: attachments,
                               attachmentsDirectory: attachments.isEmpty ? nil : attachmentsDir,
                               downloadedSnapshots: downloaded)
    }

    /// Uploads the local (unpatched) versions of `paths` over the patched ones.
    private func restoreSources(_ paths: [String], in dir: String) async {
        try? await offCooperativePool { try self.transport.upload(files: paths, from: self.repository, to: dir) }
    }

    /// Stops the remote `xcodebuild` (interrupting it, then escalating), or keeps a run that is
    /// still preparing from starting it.
    public func cancel() {
        let p: StreamingProcess? = lock.withLock {
            cancelled = true
            return process
        }
        p?.cancel(grace: 5)
    }

    private func checkCancelled() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    private func remoteScheme(environment: TestEnvironment, dir: String) throws -> String {
        if let scheme = config.scheme { return scheme }
        var args = ["xcodebuild", "-list", "-json"]
        if let ws = config.workspace { args += ["-workspace", ws] } else if let p = config.project { args += ["-project", p] }
        let workDir = config.workingDirectory.map { dir + "/" + $0 } ?? dir
        let out = try transport.run("cd \(Shell.quote(workDir)) && DEVELOPER_DIR=\(Shell.quote(environment.xcode.developerDir)) " + args.map(Shell.quote).joined(separator: " "))
        struct Listing: Decodable {
            struct C: Decodable { var schemes: [String]? }
            var project: C?
            var workspace: C?
        }
        let json = out.drop { $0 != "{" }
        if let listing = try? JSONDecoder().decode(Listing.self, from: Data(json.utf8)) {
            let schemes = listing.workspace?.schemes ?? listing.project?.schemes ?? []
            if schemes.count == 1 { return schemes[0] }
            if let pkg = schemes.first(where: { $0.hasSuffix("-Package") }) { return pkg }
        }
        throw ConfigError.missingScheme
    }

    // MARK: Record helpers

    func uploadPatchedSources(for suites: [SuiteResult], to dir: String) throws -> [String] {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-patch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        var byFile: [String: [[String]?]] = [:]
        for target in try SuiteLocator.targets(for: suites, in: repository) { byFile[target.path, default: []].append(target.suite) }
        for (path, names) in byFile {
            var text = try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
            for name in names { text = try RecordPatcher.patch(source: text, suite: name, file: path) }
            let dest = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: dest, atomically: true, encoding: .utf8)
        }
        let paths = byFile.keys.sorted()
        try transport.upload(files: paths, from: staging, to: dir)
        return paths
    }

    /// Leaves the newest of the remote Mac's result bundles in `dir`, as many runs as are kept here
    /// (its runs' images come here, their bundles stay there). A bundle's name starts with the time
    /// its run started.
    func pruneResults(in dir: String) throws {
        try transport.run("cd \(Shell.quote(dir)) && ls -1d -- *.xcresult 2>/dev/null | sort -r | tail -n +\(TestRunner.keptResults + 1) "
            + #"| while IFS= read -r bundle; do rm -rf -- "$bundle"; done"#)
    }

    func downloadRecordedSnapshots(dir: String, stateDir: String) throws -> [String] {
        // Not in the folders the sync leaves alone: package checkouts there have __Snapshots__ too.
        let out = try transport.run("cd \(Shell.quote(dir)) && find . -path '*/__Snapshots__/*' -type f -newer \(Shell.quote(stateDir + "/record-marker")) "
            + "-not -path './.snapshotkit/*' -not -path './.build/*' -not -path './.swiftpm/*' -not -path '*/DerivedData/*' | sed 's|^\\./||'")
        let paths = out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if !paths.isEmpty { try transport.download(files: paths, from: dir, to: repository) }
        return paths
    }

    // MARK: Results

    func collectSummary(bundle: String, environment: TestEnvironment, remoteDir: String) throws -> TestRunSummary {
        let json = try transport.run("DEVELOPER_DIR=\(Shell.quote(environment.xcode.developerDir)) xcrun xcresulttool get test-results tests --path \(Shell.quote(bundle))")
        var summary = try XCResultParser.parse(Data(json.utf8))
        // Map remote source and snapshot paths onto the local checkout.
        for i in summary.suites.indices {
            summary.suites[i].failureFiles = summary.suites[i].failureFiles.map { Self.mapPath($0, from: remoteDir, to: repository.path) }
            for j in summary.suites[i].tests.indices {
                summary.suites[i].tests[j].failureMessages = summary.suites[i].tests[j].failureMessages.map {
                    Self.mapPath($0, from: remoteDir, to: repository.path)
                }
            }
        }
        return summary
    }

    /// Replaces the remote checkout prefix (also in its /private/var form) with the local one.
    static func mapPath(_ text: String, from remoteDir: String, to localDir: String) -> String {
        var result = text
        for prefix in ["/private" + remoteDir, remoteDir] {
            result = result.replacingOccurrences(of: prefix + "/", with: localDir + "/")
        }
        return result
    }

    func collectAttachments(bundle: String, environment: TestEnvironment, stateDir: String, into local: URL) throws -> [SnapshotFailureImages] {
        let remoteOut = stateDir + "/attachments"
        _ = try transport.run("rm -rf \(Shell.quote(remoteOut)) && DEVELOPER_DIR=\(Shell.quote(environment.xcode.developerDir)) xcrun xcresulttool export attachments --path \(Shell.quote(bundle)) --output-path \(Shell.quote(remoteOut)) >/dev/null")
        try transport.download(remoteOut + "/", to: local)
        return try FailureAttachments.parse(manifest: Data(contentsOf: local.appendingPathComponent("manifest.json")), directory: local)
    }
}

/// An environment problem on a remote machine (same checks as locally, tagged with the host).
public struct RemoteEnvironmentError: Error, LocalizedError {
    public var host: String
    public var underlying: EnvironmentError
    public var errorDescription: String? { "On \(host): " + (underlying.errorDescription ?? "\(underlying)") }
}
