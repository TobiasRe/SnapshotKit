import Foundation

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
    public var passed: Int
    public var skipped: Int

    public init(link: GitLabLink, job: GitLabJob, mergeRequest: GitLabMergeRequest? = nil, trace: CITrace = CITrace(), summary: TestRunSummary,
                images: [SnapshotFailureImages] = [], notes: [String] = [], passed: Int = 0, skipped: Int = 0) {
        self.link = link
        self.job = job
        self.mergeRequest = mergeRequest
        self.trace = trace
        self.summary = summary
        self.images = images
        self.notes = notes
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

    /// Loads the job `link` names, writing its references and images into `directory`.
    public func load(_ link: GitLabLink, into directory: URL) throws -> CIImport {
        guard let jobID = link.jobID else { throw GitLabError.notAJob("https://\(link.host)/\(link.projectPath)", numbers: false) }
        let job = try api.job(jobID, in: link)
        var notes: [String] = []

        var trace = CITrace()
        do { trace = CITrace(log: try api.trace(ofJob: jobID, in: link)) } catch {
            notes.append("The job’s log couldn’t be read: \(error.localizedDescription)")
        }

        // The failures and their messages: the pipeline's test report has them; the log only names the tests.
        var cases: [CITestReport.Case] = [], passed = 0, skipped = 0
        if let pipeline = job.pipeline?.id {
            do {
                let report = try api.testReport(ofPipeline: pipeline, in: link)
                for suite in report.testSuites where suite.name == job.name {
                    cases += suite.testCases.filter(\.failed)
                    passed += suite.successCount ?? 0
                    skipped += suite.skippedCount ?? 0
                }
            } catch {
                notes.append("The pipeline’s test report couldn’t be read: \(error.localizedDescription)")
            }
        }
        var failures = cases.map { CIFailure(case: $0, failingTests: trace.failingTests) }
        if failures.isEmpty, !trace.failingTests.isEmpty {
            notes.append("The job uploaded no test report (`artifacts: reports: junit:`), so its failure messages, references and images are unknown.")
            failures = trace.failingTests.map { CIFailure(bundle: $0.bundle, suite: $0.suite, name: $0.name, message: "") }
        }

        // The images: the references at the job's commit, the actual ones from the runner.
        let mismatches = failures.map { SnapshotMismatch.parse($0.message) }
        var references: [String: URL] = [:]
        if !mismatches.joined().isEmpty {
            references = fetchReferences(mismatches.joined().compactMap(\.reference), sha: job.sha, trace: trace, into: directory, notes: &notes)
        }
        var actuals: [String: URL] = [:]
        if fetchImages {
            let paths = Array(Set(mismatches.joined().compactMap(\.actual))).sorted()
            if !paths.isEmpty { actuals = fetchActualImages(paths, runner: job.runner?.description, into: directory, notes: &notes) }
        }

        var suites: [SuiteResult] = []
        var images: [SnapshotFailureImages] = []
        for (failure, mismatches) in zip(failures, mismatches) {
            // The target: the report's or the log's, else the folder holding `__Snapshots__` (named for it more
            // often than not), else the scheme.
            let bundle = failure.bundle ?? mismatches.compactMap(\.reference).compactMap(Self.folderAboveSnapshots).first
                ?? trace.scheme ?? job.name
            let test = TestCaseResult(name: failure.name, identifier: failure.identifier, outcome: .failed,
                                      failureMessages: failure.message.isEmpty ? [] : [failure.message], repetitions: [.failed])
            if let i = suites.firstIndex(where: { $0.bundle == bundle && $0.path == failure.suite }) {
                suites[i].tests.append(test)
            } else {
                suites.append(SuiteResult(bundle: bundle, path: failure.suite, tests: [test], failureFiles: []))
            }
            for (index, mismatch) in mismatches.enumerated() where mismatch.reference != nil || mismatch.actual != nil {
                images.append(SnapshotFailureImages(
                    testIdentifier: failure.identifier, bundle: bundle, repetition: 1, index: index,
                    reference: mismatch.reference.flatMap { references[$0] }, failure: mismatch.actual.flatMap { actuals[$0] },
                    device: job.runner?.description,
                    referencePath: mismatch.reference.flatMap { relativePath($0, trace: trace, sha: job.sha) }))
            }
        }
        let mergeRequest = job.ref.flatMap { try? api.openMergeRequests(from: $0, in: link).first }
        return CIImport(link: link, job: job, mergeRequest: mergeRequest, trace: trace, summary: TestRunSummary(suites: suites),
                        images: images, notes: notes, passed: passed, skipped: skipped)
    }

    // MARK: References

    /// The references as they were at `sha`, the commit the job ran: the working tree may have been re-recorded
    /// since. When the commit isn't in this clone, the working tree's, with a note saying so.
    func fetchReferences(_ runnerPaths: [String], sha: String?, trace: CITrace, into directory: URL,
                         notes: inout [String]) -> [String: URL] {
        var found: [String: URL] = [:]
        let git = Git(root: repository)
        let commit = sha.flatMap { git.tryRun(["cat-file", "-e", $0 + "^{commit}"]) != nil ? $0 : nil }
        if let sha, commit == nil {
            notes.append("The job’s commit \(sha.prefix(8)) isn’t in this clone, so its references are the working tree’s, which may "
                         + "have changed since. `git fetch` to compare with the job’s own.")
        }
        for runnerPath in Set(runnerPaths) {
            guard let path = relativePath(runnerPath, trace: trace, sha: commit) else { continue }
            let data = commit.flatMap { git.show(revision: $0, path: path) }
                ?? (commit == nil ? FileManager.default.contents(atPath: repository.appendingPathComponent(path).path) : nil)
            guard let data else { continue }
            let url = directory.appendingPathComponent("reference").appendingPathComponent(path)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                found[runnerPath] = url
            } catch {
                notes.append("Couldn’t write the reference \(path): \(error.localizedDescription)")
            }
        }
        return found
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

    /// Copies the images the tests took from the runner, those still there. rsync stops at the first missing
    /// file, so which are there is asked first, with every path quoted: they come from failure messages,
    /// which the tests' authors write.
    func fetchActualImages(_ paths: [String], runner: String?, into directory: URL, notes: inout [String]) -> [String: URL] {
        guard let runner, !runner.isEmpty else {
            notes.append("The job doesn’t name its runner, so the images its tests took can’t be copied.")
            return [:]
        }
        let destination = Self.destination(login: login, runner: runner)
        do {
            let remote = try transport(destination)
            let check = "for f in " + paths.map(Shell.quote).joined(separator: " ") + "; do [ -f \"$f\" ] && printf '%s\\n' \"$f\"; done; true"
            let present = Set(try remote.run(check).split(separator: "\n").map(String.init)).intersection(paths)
            let gone = paths.count - present.count
            if gone > 0 {
                notes.append("\(gone == paths.count ? "The" : "\(gone) of the \(paths.count)") images the tests took "
                             + "\(gone == 1 ? "is" : "are") no longer on \(runner): it removes them when its next job starts. "
                             + "Run the job again to see \(gone == 1 ? "it" : "them").")
            }
            guard !present.isEmpty else { return [:] }
            let local = directory.appendingPathComponent("actual", isDirectory: true)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            // Relative to the root, which rsync can name safely; the list itself may hold anything.
            try remote.download(files: present.sorted().map { String($0.drop { $0 == "/" }) }, from: "/", to: local)
            return Dictionary(uniqueKeysWithValues: present.map { ($0, local.appendingPathComponent(String($0.drop { $0 == "/" }))) })
        } catch {
            notes.append(sshHint(for: error, destination: destination, runner: runner, paths: paths))
            return [:]
        }
    }

    /// Where to log in: a bare user on the runner, `user@host` as given, or the runner with ssh's default user.
    static func destination(login: String?, runner: String) -> String {
        guard let login = login?.trimmingCharacters(in: .whitespaces), !login.isEmpty else { return runner }
        return login.contains("@") ? login : "\(login)@\(runner)"
    }

    /// What went wrong reaching the runner, and what to do about it.
    func sshHint(for error: Error, destination: String, runner: String, paths: [String]) -> String {
        let output = error.localizedDescription
        if output.contains("Host key verification failed") {
            return "\(runner) isn’t a known SSH host yet, and SnapshotKit never trusts one by itself. Connect once with "
                + "`ssh \(destination) true` and accept its key, then load the job again."
        }
        if output.contains("Permission denied") {
            // The images are in a user's folder: that user is likely the one to log in as.
            let owner = paths.lazy.compactMap { path -> String? in
                let parts = path.split(separator: "/")
                return parts.count > 2 && parts[0] == "Users" ? String(parts[1]) : nil
            }.first
            let hint = (login ?? "").isEmpty && owner != nil
                ? " The images are in /Users/\(owner!)/: set CI login in the Run tab to `\(owner!)`."
                : " Check CI login in the Run tab, and that `ssh \(destination) true` works without a password."
            return "\(destination) refused the SSH login, so the images the tests took couldn’t be copied." + hint
        }
        return "Couldn’t copy the images the tests took from \(runner): \(output)"
    }
}
