import Foundation

/// Something to do about what a CI job's load couldn't fetch, offered with the notes.
public enum CIFix: Hashable, Sendable {
    /// Log in to the runner as this (CI login under Run, `--ci-login`), then load the job again.
    case useLogin(String)
    /// A command to run in a terminal first, such as `ssh user@runner true` to trust the runner's host key.
    case runCommand(String)
    /// Retry the job on GitLab: its runner no longer has the images it took. The retry is a new job.
    case retryJob
    /// Load the job again, once something has changed.
    case loadAgain
}

/// A CI job's failing tests, as the app shows a run's: the tests, the references at the commit the job
/// ran, the images the runner took, and notes on what couldn't be had.
public struct CIImport: Sendable {
    public var link: GitLabLink
    public var job: GitLabJob
    /// The merge request whose branch the job ran, if one is open.
    public var mergeRequest: GitLabMergeRequest?
    public var trace: CITrace
    public var summary: TestRunSummary
    public var images: [SnapshotFailureImages]
    /// What couldn't be fetched (images gone from the runner, SSH, a commit missing here). The failures show anyway.
    public var notes: [String]
    /// What would fetch what couldn't be, most useful first.
    public var fixes: [CIFix]
    public var passed: Int
    public var skipped: Int

    public init(link: GitLabLink, job: GitLabJob, mergeRequest: GitLabMergeRequest? = nil, trace: CITrace = CITrace(), summary: TestRunSummary,
                images: [SnapshotFailureImages] = [], notes: [String] = [], fixes: [CIFix] = [], passed: Int = 0, skipped: Int = 0) {
        self.link = link
        self.job = job
        self.mergeRequest = mergeRequest
        self.trace = trace
        self.summary = summary
        self.images = images
        self.notes = notes
        self.fixes = fixes
        self.passed = passed
        self.skipped = skipped
    }
}

/// Loads a CI job's failures. Reads GitLab through `api`, the references through git, and the images over
/// SSH from the runner, where they stay until its next job starts. SSH is key-based and never interactive:
/// SnapshotKit asks for no password and accepts no host key by itself.
public struct CIImporter: Sendable {
    public var api: GitLabAPI
    public var repository: URL
    /// The SSH login on the runner: a user (`user@<runner>`), `user@host` (as is), or nil for ssh's own default.
    public var login: String?
    public var fetchImages = true
    /// The transport to an SSH destination; tests pass a local one.
    public var transport: @Sendable (String) throws -> RemoteTransport = { try SSHTransport(host: $0) }

    public init(api: GitLabAPI, repository: URL, login: String? = nil, fetchImages: Bool = true) {
        self.api = api
        self.repository = repository
        self.login = login
        self.fetchImages = fetchImages
    }

    /// Loads the job `link` names, writing its references and images into `directory`. Images an earlier load
    /// copied into the same folder are kept: the runner removes them when its next job starts.
    public func load(_ link: GitLabLink, into directory: URL) throws -> CIImport {
        guard let jobID = link.jobID else { throw GitLabError.notAJob("https://\(link.host)/\(link.projectPath)", numbers: false) }
        let job: GitLabJob
        do {
            job = try api.job(jobID, in: link)
        } catch let error as GitLabError where error.isNotFound {
            throw GitLabError.jobNotFound(id: jobID, project: link.projectPath, host: link.host)
        }
        var notes: [String] = [], fixes: [CIFix] = []

        var trace = CITrace()
        do { trace = CITrace(log: try api.trace(ofJob: jobID, in: link)) } catch {
            notes.append("The job’s log couldn’t be read: \(error.localizedDescription)")
        }

        // The failures and their messages: the pipeline's test report has them; the log only names the tests.
        var cases: [CITestReport.Case] = [], passed = 0, skipped = 0
        var otherSuites: [String]?
        if let pipeline = job.pipeline?.id {
            do {
                let report = try api.testReport(ofPipeline: pipeline, in: link)
                let suites = report.testSuites.filter { Self.suite($0.name, isOf: job.name) }
                for suite in suites {
                    cases += suite.testCases.filter(\.failed)
                    passed += suite.successCount ?? 0
                    skipped += suite.skippedCount ?? 0
                }
                if suites.isEmpty, !report.testSuites.isEmpty { otherSuites = report.testSuites.map(\.name) }
            } catch {
                notes.append("The pipeline’s test report couldn’t be read: \(error.localizedDescription)")
            }
        }
        var failures = cases.map { CIFailure(case: $0, failingTests: trace.failingTests) }
        if failures.isEmpty, !trace.failingTests.isEmpty {
            if let otherSuites {
                notes.append("The pipeline’s test report has no suite for \(job.name), only for "
                             + Self.list(otherSuites.map { "“\($0)”" }) + ", so its failure messages, references and images are unknown.")
            } else {
                notes.append("The job uploaded no test report (`artifacts: reports: junit:`), so its failure messages, references and images are unknown.")
            }
            failures = trace.failingTests.map { CIFailure(bundle: $0.bundle, suite: $0.suite, name: $0.name, message: "") }
        } else if failures.isEmpty, ["running", "pending", "created", "preparing", "waiting_for_resource"].contains(job.status) {
            notes.append("\(job.name) hasn’t finished yet (\(job.status)). Load it again once it has.")
            fixes.append(.loadAgain)
        } else if failures.isEmpty, job.status == "failed" {
            notes.append("\(job.name) failed, but neither its test report nor its log names a failing test: it failed outside the tests "
                         + "(building, a script step, a timeout). Its log on GitLab says why.")
        }
        // A message kept as a string literal reads as one unescaped.
        failures = failures.map { failure in
            var failure = failure
            failure.message = SnapshotMismatch.readable(failure.message)
            return failure
        }

        // The images: the references at the job's commit, the actual ones from the runner. Text snapshots
        // have their difference in the message.
        let mismatches = failures.map { SnapshotMismatch.parse($0.message) }
        let named = mismatches.joined().filter { $0.namesImages && $0.isImage }
        let unnamed = zip(failures, mismatches).filter { failure, mismatches in
            !mismatches.contains(where: \.namesImages) && SnapshotMismatch.isSnapshotFailure(failure.message)
        }.map(\.0.name)
        if !unnamed.isEmpty {
            notes.append((unnamed.count == 1 ? "The failure message of \(unnamed[0]) says" : "The failure messages of \(Self.list(unnamed)) say")
                         + " a snapshot didn’t match, but name\(unnamed.count == 1 ? "s" : "") no image files, so there is nothing to "
                         + "fetch. The test report may cut long messages short.")
        }
        var references: [String: URL] = [:], referenceProblems: [String: String] = [:]
        let referencePaths = named.compactMap(\.reference)
        if !referencePaths.isEmpty {
            (references, referenceProblems) = fetchReferences(referencePaths, sha: job.sha, trace: trace, into: directory, notes: &notes)
        }
        var actuals: [String: URL] = [:], actualProblems: [String: String] = [:]
        let actualPaths = Array(Set(named.compactMap(\.actual))).sorted()
        if fetchImages, !actualPaths.isEmpty {
            (actuals, actualProblems) = fetchActualImages(actualPaths, runner: job.runner?.description, into: directory,
                                                          notes: &notes, fixes: &fixes)
        } else if !actualPaths.isEmpty {
            actualProblems = Dictionary(uniqueKeysWithValues: actualPaths.map { ($0, "Not copied from the runner: images weren’t asked for.") })
        }

        var suites: [SuiteResult] = []
        var images: [SnapshotFailureImages] = []
        for (failure, mismatches) in zip(failures, mismatches) {
            // The target: the report's or the log's, else the folder holding `__Snapshots__` (named for it more
            // often than not), else the scheme.
            let bundle = failure.bundle ?? mismatches.compactMap { $0.reference ?? ($0.recorded ? $0.actual : nil) }
                .compactMap(Self.folderAboveSnapshots).first ?? trace.scheme ?? job.name
            let test = TestCaseResult(name: failure.name, identifier: failure.identifier, outcome: .failed,
                                      failureMessages: failure.message.isEmpty ? [] : [failure.message], repetitions: [.failed])
            if let i = suites.firstIndex(where: { $0.bundle == bundle && $0.path == failure.suite }) {
                suites[i].tests.append(test)
            } else {
                suites.append(SuiteResult(bundle: bundle, path: failure.suite, tests: [test], failureFiles: []))
            }
            for (index, mismatch) in mismatches.enumerated() where mismatch.namesImages && mismatch.isImage {
                // A recorded reference is the image taken, under `__Snapshots__` on the runner.
                let referencePath = mismatch.reference ?? (mismatch.recorded ? mismatch.actual : nil)
                let referenceMissing: String? = if let reference = mismatch.reference {
                    references[reference] == nil ? referenceProblems[reference] : nil
                } else if mismatch.recorded {
                    "No reference was committed: the test recorded the image it took as the new reference, on the runner. "
                        + "Record it here and commit it."
                } else {
                    "The failure message doesn’t say where the reference is."
                }
                let failureMissing: String? = if let actual = mismatch.actual {
                    actuals[actual] == nil ? actualProblems[actual] : nil
                } else {
                    "The failure message doesn’t say where the image the test took is."
                }
                images.append(SnapshotFailureImages(
                    testIdentifier: failure.identifier, bundle: bundle, repetition: 1, index: index,
                    reference: mismatch.reference.flatMap { references[$0] }, failure: mismatch.actual.flatMap { actuals[$0] },
                    device: job.runner?.description,
                    referencePath: referencePath.flatMap { relativePath($0, trace: trace, sha: job.sha) },
                    referenceMissing: referenceMissing, failureMissing: failureMissing))
            }
        }
        let mergeRequest = job.ref.flatMap { try? api.openMergeRequests(from: $0, in: link).first }
        var unique: [CIFix] = []
        for fix in fixes where !unique.contains(fix) { unique.append(fix) }
        return CIImport(link: link, job: job, mergeRequest: mergeRequest, trace: trace, summary: TestRunSummary(suites: suites),
                        images: images, notes: notes, fixes: unique, passed: passed, skipped: skipped)
    }

    /// Whether a test report's suite is the job's: GitLab names it after the job, without the `1/3` of a
    /// parallel one.
    static func suite(_ suite: String, isOf job: String) -> Bool {
        suite == job || suite == job.replacingOccurrences(of: #"\s+\d+/\d+$"#, with: "", options: .regularExpression)
    }

    /// `a`, `a and b`, `a, b and c`, `a, b, c and 2 more`.
    static func list(_ items: [String]) -> String {
        let shown = items.count > 4 ? Array(items.prefix(3)) + ["\(items.count - 3) more"] : items
        return shown.count < 2 ? shown.joined() : shown.dropLast().joined(separator: ", ") + " and " + shown.last!
    }

    // MARK: References

    /// The references as they were at `sha`, the commit the job ran: the working tree may have been re-recorded
    /// since. When the commit isn't in this clone, the working tree's, with a note saying so. Those not found,
    /// with why.
    func fetchReferences(_ runnerPaths: [String], sha: String?, trace: CITrace, into directory: URL,
                         notes: inout [String]) -> (found: [String: URL], missing: [String: String]) {
        var found: [String: URL] = [:], missing: [String: String] = [:]
        let git = Git(root: repository)
        let commit = sha.flatMap { git.tryRun(["cat-file", "-e", $0 + "^{commit}"]) != nil ? $0 : nil }
        if let sha, commit == nil {
            notes.append("The job’s commit \(sha.prefix(8)) isn’t in this clone, so its references are the working tree’s, which may "
                         + "have changed since. `git fetch` to compare with the job’s own.")
        }
        for runnerPath in Set(runnerPaths) {
            guard let path = relativePath(runnerPath, trace: trace, sha: commit) else {
                missing[runnerPath] = "Its path on the runner (\(runnerPath)) is no file of this clone"
                    + (commit.map { " at the job’s commit \($0.prefix(8))" } ?? "") + ": is this the project the job tested?"
                continue
            }
            let data = commit.flatMap { git.show(revision: $0, path: path) }
                ?? (commit == nil ? FileManager.default.contents(atPath: repository.appendingPathComponent(path).path) : nil)
            guard let data else {
                missing[runnerPath] = commit.map { "\(path) isn’t in the job’s commit \($0.prefix(8))." }
                    ?? "\(path) isn’t in the working tree, and the job’s commit isn’t in this clone: `git fetch`, then load the job again."
                continue
            }
            let url = directory.appendingPathComponent("reference").appendingPathComponent(path)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                found[runnerPath] = url
            } catch {
                notes.append("Couldn’t write the reference \(path): \(error.localizedDescription)")
                missing[runnerPath] = "Couldn’t be written here: \(error.localizedDescription)"
            }
        }
        return (found, missing)
    }

    /// A path on the runner made the repository's: below the folder the job checked the project out to, else
    /// the longest tail from above `__Snapshots__` that is a file at `sha` (or in the working tree).
    func relativePath(_ runnerPath: String, trace: CITrace, sha: String?) -> String? {
        if let root = trace.projectDirectory, runnerPath.hasPrefix(root + "/") { return String(runnerPath.dropFirst(root.count + 1)) }
        let components = runnerPath.split(separator: "/")
        guard let snapshots = components.firstIndex(of: "__Snapshots__") else { return nil }
        let git = Git(root: repository)
        for start in 0..<snapshots {
            let tail = components[start...].joined(separator: "/")
            if let sha, git.tryRun(["cat-file", "-e", "\(sha):\(tail)"]) != nil { return tail }
            if FileManager.default.fileExists(atPath: repository.appendingPathComponent(tail).path) { return tail }
        }
        return nil
    }

    static func folderAboveSnapshots(_ path: String) -> String? {
        let components = path.split(separator: "/")
        guard let snapshots = components.firstIndex(of: "__Snapshots__"), snapshots > 0 else { return nil }
        return String(components[snapshots - 1])
    }

    // MARK: Images from the runner

    /// Copies the images the tests took from the runner, those still there, and says why for the others. rsync
    /// stops at the first missing file, so which are there (and readable by the login) is asked first, with
    /// every path quoted: they come from failure messages, which the tests' authors write. Images an earlier
    /// load copied into `directory` are kept, not asked for again.
    func fetchActualImages(_ paths: [String], runner: String?, into directory: URL, notes: inout [String],
                           fixes: inout [CIFix]) -> (found: [String: URL], missing: [String: String]) {
        let local = directory.appendingPathComponent("actual", isDirectory: true)
        func localURL(_ path: String) -> URL { local.appendingPathComponent(String(path.drop { $0 == "/" })) }
        var found: [String: URL] = [:]
        for path in paths where FileManager.default.fileExists(atPath: localURL(path).path) { found[path] = localURL(path) }
        let wanted = paths.filter { found[$0] == nil }
        guard !wanted.isEmpty else { return (found, [:]) }

        guard let runner, !runner.isEmpty else {
            notes.append("The job doesn’t name its runner, so the images its tests took can’t be copied.")
            return (found, Dictionary(uniqueKeysWithValues: wanted.map { ($0, "The job doesn’t name its runner, so this image couldn’t be copied.") }))
        }
        let destination = Self.destination(login: login, runner: runner)
        var missing: [String: String] = [:]
        do {
            let remote = try transport(destination)
            let state = RunnerFiles(output: try remote.run(RunnerFiles.script(wanted)), asked: wanted)

            if !state.unreadable.isEmpty {
                let owner = state.unreadable.lazy.compactMap(Self.homeOwner).first
                let home = state.unreadable.lazy.compactMap(Self.homeFolder).first ?? owner.map { "/Users/\($0)/" }
                let user = state.user ?? destination
                let suggestion = owner.flatMap { $0 == state.user ? nil : Self.login(owner: $0, replacing: login) }
                let count = state.unreadable.count
                notes.append("Logged in to \(runner) as \(user), who can’t read \(count == paths.count ? "the" : "\(count) of the \(paths.count)") "
                             + "images the tests took" + (home.map { ": they are in \($0)" } ?? "") + "."
                             + (suggestion.map { " Set CI login under Run to `\($0)`." } ?? " Check the folders’ permissions on \(runner)."))
                if let suggestion { fixes.append(.useLogin(suggestion)) }
                for path in state.unreadable {
                    missing[path] = "\(user) on \(runner) can’t read it" + (owner.map { ": it is \($0)’s" } ?? "")
                        + (suggestion.map { ". Log in as `\($0)` (CI login under Run)." } ?? ".")
                }
            }
            let gone = state.gone.count
            if gone > 0 {
                // Counted among all the job's images, those kept from an earlier load too.
                let which = gone < paths.count ? "\(gone) of the \(paths.count) images the tests took \(gone == 1 ? "is" : "are")"
                    : gone == 1 ? "The image the test took is" : "The images the tests took are"
                notes.append("\(which) no longer on \(runner): it removes them when its next job starts. "
                             + "Run the job again to see \(gone == 1 ? "it" : "them").")
                fixes.append(.retryJob)
                for path in state.gone {
                    missing[path] = "No longer on \(runner): it removes the images the tests took when its next job starts. "
                        + "Retry the job on GitLab and load the new one to see it."
                }
            }
            guard !state.present.isEmpty else { return (found, missing) }
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            // Relative to the root, which rsync can name safely; the list itself may hold anything.
            try remote.download(files: state.present.sorted().map { String($0.drop { $0 == "/" }) }, from: "/", to: local)
            for path in state.present { found[path] = localURL(path) }
            return (found, missing)
        } catch {
            let diagnosis = sshDiagnosis(for: error, destination: destination, runner: runner, paths: wanted)
            notes.append(diagnosis.note)
            fixes += diagnosis.fixes
            for path in wanted where missing[path] == nil { missing[path] = diagnosis.reason }
            return (found, missing)
        }
    }

    /// Which of the files asked for the runner has, which the login can't read, and which are gone, from
    /// `script`'s output.
    struct RunnerFiles {
        var asked: [String]
        var user: String?
        var present: [String] = []
        var unreadable: [String] = []
        var gone: [String] { asked.filter { !present.contains($0) && !unreadable.contains($0) } }

        /// Prints `user`, then `ok` or `denied` and each path there or behind a folder the login can't open.
        static func script(_ paths: [String]) -> String {
            "printf 'user\\t%s\\n' \"$(id -un 2>/dev/null)\"; for f in " + paths.map(Shell.quote).joined(separator: " ") + "; do "
                + "if [ -f \"$f\" ]; then if [ -r \"$f\" ]; then printf 'ok\\t%s\\n' \"$f\"; else printf 'denied\\t%s\\n' \"$f\"; fi; "
                + "else d=$(dirname \"$f\"); while [ ! -e \"$d\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; "
                + "if [ -d \"$d\" ] && [ ! -x \"$d\" ]; then printf 'denied\\t%s\\n' \"$f\"; fi; fi; done; true"
        }

        init(output: String, asked: [String]) {
            self.asked = asked
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "user": user = parts[1].isEmpty ? nil : parts[1]
                case "ok" where asked.contains(parts[1]) && !present.contains(parts[1]): present.append(parts[1])
                case "denied" where asked.contains(parts[1]) && !unreadable.contains(parts[1]): unreadable.append(parts[1])
                default: break
                }
            }
        }
    }

    /// Where to log in: a bare user on the runner, `user@host` as given, or the runner with ssh's default user.
    static func destination(login: String?, runner: String) -> String {
        guard let login = login?.trimmingCharacters(in: .whitespaces), !login.isEmpty else { return runner }
        return login.contains("@") ? login : "\(login)@\(runner)"
    }

    /// The user whose home folder a path is in: `/Users/<user>/…`, or `/home/<user>/…` on Linux.
    static func homeOwner(of path: String) -> String? {
        homeFolder(of: path).map { String($0.split(separator: "/")[1]) }
    }

    /// `/Users/<user>/` of a path in it, or `/home/<user>/`.
    static func homeFolder(of path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count > 2, parts[0] == "Users" || parts[0] == "home", parts[1] != "Shared" else { return nil }
        return "/\(parts[0])/\(parts[1])/"
    }

    /// `owner` as the CI login: on the host the login names, if it names one.
    static func login(owner: String, replacing login: String?) -> String {
        guard let login = login?.trimmingCharacters(in: .whitespaces), let at = login.lastIndex(of: "@") else { return owner }
        return owner + login[at...]
    }

    /// What went wrong reaching the runner: a note for the job, a reason for each image, and what to do.
    struct SSHDiagnosis: Equatable {
        var note: String
        var reason: String
        var fixes: [CIFix] = []
    }

    /// What went wrong reaching the runner, and what to do about it.
    func sshHint(for error: Error, destination: String, runner: String, paths: [String]) -> String {
        sshDiagnosis(for: error, destination: destination, runner: runner, paths: paths).note
    }

    func sshDiagnosis(for error: Error, destination: String, runner: String, paths: [String]) -> SSHDiagnosis {
        let output = error.localizedDescription
        let said: String = switch error {
        case let RemoteError.commandFailed(_, _, _, output), let RemoteError.syncFailed(_, output), let RemoteError.unreachable(_, output): output
        default: output
        }
        let host = destination.split(separator: "@").last.map(String.init) ?? runner
        let user = destination.contains("@") ? destination.split(separator: "@").dropLast().joined(separator: "@") : nil
        let owner = paths.lazy.compactMap(Self.homeOwner).first
        let home = paths.lazy.compactMap(Self.homeFolder).first ?? ""

        if case RemoteError.invalidHost = error {
            return (login ?? "").contains("@")
                ? SSHDiagnosis(note: "CI login “\(destination)” isn’t a login ssh can use, so the images the tests took couldn’t be copied. "
                               + "Set CI login under Run to a user, or `user@host`.",
                               reason: "CI login “\(destination)” isn’t a login ssh can use.")
                : SSHDiagnosis(note: "GitLab names the runner “\(runner)”, which isn’t a host name, so the images the tests took couldn’t be "
                               + "copied. Set CI login under Run to `user@host`, with the runner’s address.",
                               reason: "The runner’s name “\(runner)” isn’t a host name: set CI login under Run to `user@host`.")
        }
        if output.contains("Host key verification failed") {
            return SSHDiagnosis(
                note: "\(runner) isn’t a known SSH host yet, and SnapshotKit never trusts one by itself. Connect once with "
                    + "`ssh \(destination) true` and accept its key, then load the job again.",
                reason: "\(runner) isn’t a known SSH host yet: connect once with `ssh \(destination) true`, then load the job again.",
                fixes: [.runCommand("ssh \(destination) true"), .loadAgain])
        }
        if output.contains("Permission denied (13)") || output.contains("failed to open") {
            let suggestion = owner.flatMap { $0 == user ? nil : Self.login(owner: $0, replacing: login) }
            return SSHDiagnosis(
                note: "\(destination) can’t read the images the tests took" + (owner == nil ? "" : ": they are in \(home)") + "."
                    + (suggestion.map { " Set CI login under Run to `\($0)`." } ?? " Check the folders’ permissions on \(runner)."),
                reason: "\(destination) can’t read it" + (suggestion.map { ": log in as `\($0)` (CI login under Run)." } ?? "."),
                fixes: suggestion.map { [.useLogin($0)] } ?? [])
        }
        if output.contains("Permission denied") {
            // The images are in a user's folder: that user is likely the one to log in as.
            let refused = "\(destination) refused the SSH login, so the images the tests took couldn’t be copied."
            let check = " Check CI login under Run, and that `ssh \(destination) true` works without a password."
            guard let owner, owner != user else {
                return SSHDiagnosis(note: refused + check + " SnapshotKit can’t type a key’s passphrase: add the key to ssh-agent "
                                    + "(`ssh-add --apple-use-keychain`), or name it in ~/.ssh/config.",
                                    reason: "\(destination) refused the SSH login: check that `ssh \(destination) true` works without a password.",
                                    fixes: [.runCommand("ssh \(destination) true"), .loadAgain])
            }
            let suggestion = Self.login(owner: owner, replacing: login)
            let suggested = Self.destination(login: suggestion, runner: runner)
            let note = (login ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                ? refused + " The images are in \(home): set CI login under Run to `\(owner)`."
                : refused + " The images are in \(home), so the login is likely `\(suggestion)`: set CI login under Run to it."
                    + " Otherwise check CI login under Run, and that `ssh \(destination) true` works without a password."
            return SSHDiagnosis(note: note,
                                reason: "\(destination) refused the SSH login. The images are \(owner)’s: log in as `\(suggestion)` (CI login under Run).",
                                fixes: [.useLogin(suggestion), .runCommand("ssh \(suggested) true")])
        }
        if output.contains("Could not resolve hostname") || output.contains("nodename nor servname") {
            return SSHDiagnosis(
                note: "This Mac can’t find \(host) on the network, so the images the tests took couldn’t be copied. GitLab names the runner "
                    + "“\(runner)”, which may not be its address here: set CI login under Run to `user@address`, or give it a "
                    + "`Host \(host)` entry with its `HostName` in ~/.ssh/config.",
                reason: "This Mac can’t find \(host): set CI login under Run to `user@address`.")
        }
        if ["timed out", "No route to host", "Connection refused", "Network is unreachable", "Connection closed"].contains(where: output.contains) {
            return SSHDiagnosis(
                note: "Couldn’t copy the images the tests took from \(runner): \(host) didn’t answer over SSH (\(Self.lastLine(said))). "
                    + "Check that you’re on its network (or VPN) and that Remote Login is on there, then load the job again.",
                reason: "\(host) didn’t answer over SSH: check the network or VPN, then load the job again.",
                fixes: [.loadAgain])
        }
        return SSHDiagnosis(note: "Couldn’t copy the images the tests took from \(runner): \(output)",
                            reason: "Couldn’t be copied from \(runner): \(Self.lastLine(said))")
    }

    private static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? text
    }
}
