import Foundation

/// Reads GitLab's REST API (`/api/v4/…`). Requests are read-only: SnapshotKit never changes anything on GitLab.
public protocol GitLabAPI: Sendable {
    /// The response body of `GET /api/v4/<path>`; `path` may carry a query.
    func get(_ path: String) throws -> Data
}

public enum GitLabError: Error, LocalizedError, Equatable {
    /// Neither `glab` nor a token can reach the host.
    case noAccess(host: String, detail: String)
    case request(path: String, output: String)
    /// What was pasted for a job names none.
    case notAJob(String, numbers: Bool)

    public var errorDescription: String? {
        switch self {
        case let .noAccess(host, detail):
            "SnapshotKit can’t reach the GitLab API on \(host) (\(detail)). Sign in with `glab auth login --hostname \(host)`, "
                + "or set GITLAB_TOKEN to an access token with read_api."
        case let .request(path, output):
            "GitLab answered `\(path)` with: \(output)"
        case let .notAJob(text, numbers):
            "“\(text)” isn’t a GitLab job’s URL (https://gitlab.example.com/group/project/-/jobs/123)" + (numbers ? ", nor a job number." : ".")
        }
    }
}

extension GitLabAPI {
    /// The response decoded as GitLab's snake_case JSON.
    public func get<T: Decodable>(_ path: String, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: try get(path))
    }

    public func job(_ id: Int, in project: GitLabLink) throws -> GitLabJob {
        try get("projects/\(project.projectID)/jobs/\(id)", as: GitLabJob.self)
    }

    /// The job's log as the runner wrote it, with its colours and section markers.
    public func trace(ofJob id: Int, in project: GitLabLink) throws -> String {
        String(decoding: try get("projects/\(project.projectID)/jobs/\(id)/trace"), as: UTF8.self)
    }

    /// The JUnit reports of a pipeline's jobs: the failure messages, which the log doesn't have.
    public func testReport(ofPipeline id: Int, in project: GitLabLink) throws -> CITestReport {
        try get("projects/\(project.projectID)/pipelines/\(id)/test_report", as: CITestReport.self)
    }

    public func openMergeRequests(from branch: String, in project: GitLabLink) throws -> [GitLabMergeRequest] {
        let branch = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? branch
        return try get("projects/\(project.projectID)/merge_requests?state=opened&source_branch=\(branch)", as: [GitLabMergeRequest].self)
    }

    /// One merge request, with its latest pipeline (`head_pipeline`), which the list leaves out.
    public func mergeRequest(_ iid: Int, in project: GitLabLink) throws -> GitLabMergeRequest {
        try get("projects/\(project.projectID)/merge_requests/\(iid)", as: GitLabMergeRequest.self)
    }

    public func failedJobs(ofPipeline id: Int, in project: GitLabLink) throws -> [GitLabJob] {
        try get("projects/\(project.projectID)/pipelines/\(id)/jobs?scope%5B%5D=failed&per_page=100", as: [GitLabJob].self)
    }
}

/// The API through the `glab` CLI, signed in with `glab auth login`. Not with `NO_PROMPT` set: glab
/// prints a deprecation warning for it into the output.
public struct GlabAPI: GitLabAPI {
    public var host: String

    public init(host: String) { self.host = host }

    public func get(_ path: String) throws -> Data {
        let command = ["glab", "api", "--hostname", host, path]
        let result = try Shell.run(command, environment: ["PATH": Self.searchPath])
        guard result.succeeded else { throw CommandError(command: command, result: result) }
        return Data(result.stdout.utf8)
    }

    /// The app's PATH is launchd's, without Homebrew's folders, where glab usually is.
    static var searchPath: String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return ([path] + ["/opt/homebrew/bin", "/usr/local/bin"].filter { !path.split(separator: ":").contains(Substring($0)) })
            .joined(separator: ":")
    }
}

/// The API with an access token, through curl. The header goes in on stdin, so the token never shows
/// in the command line other processes can read (`ps`).
public struct TokenAPI: GitLabAPI {
    public var host: String
    var token: String

    public init(host: String, token: String) {
        self.host = host
        self.token = token
    }

    public func get(_ path: String) throws -> Data {
        let url = "https://\(host)/api/v4/\(path)"
        let result = try Shell.run(["curl", "-sS", "--fail-with-body", "-H", "@-", url], input: Data("PRIVATE-TOKEN: \(token)\n".utf8))
        guard result.succeeded else {
            throw GitLabError.request(path: path, output: (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Data(result.stdout.utf8)
    }
}

/// `glab` when it's installed and signed in, else a token from `GITLAB_TOKEN` or `GITLAB_PRIVATE_TOKEN`.
public struct DefaultGitLabAPI: GitLabAPI {
    public var host: String
    var glab: GitLabAPI
    var token: GitLabAPI?

    public init(host: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.host = host
        glab = GlabAPI(host: host)
        token = (environment["GITLAB_TOKEN"] ?? environment["GITLAB_PRIVATE_TOKEN"]).flatMap { $0.isEmpty ? nil : TokenAPI(host: host, token: $0) }
    }

    public func get(_ path: String) throws -> Data {
        do {
            return try glab.get(path)
        } catch let error as CommandError {
            if let token { return try token.get(path) }
            let detail = error.isNotFound ? "glab isn’t installed"
                : error.result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "glab failed"
            // A missing project or job reads the same either way; only access problems need the hint.
            if !error.isNotFound, !detail.contains("401"), !detail.contains("403"), !detail.lowercased().contains("auth") {
                throw GitLabError.request(path: path, output: detail)
            }
            throw GitLabError.noAccess(host: host, detail: detail)
        }
    }
}

// MARK: - Models

public struct GitLabPipeline: Decodable, Sendable, Equatable {
    public var id: Int
    public var sha: String?
    public var status: String?
    public var webUrl: String?

    public init(id: Int, sha: String? = nil, status: String? = nil, webUrl: String? = nil) {
        self.id = id
        self.sha = sha
        self.status = status
        self.webUrl = webUrl
    }
}

public struct GitLabJob: Decodable, Sendable, Equatable, Identifiable {
    public struct Commit: Decodable, Sendable, Equatable {
        public var id: String
        public var title: String?
    }
    public struct Runner: Decodable, Sendable, Equatable {
        public var id: Int?
        /// What the runner was registered as; for a shell runner on a Mac, usually the Mac's host name.
        public var description: String?
    }

    public var id: Int
    public var name: String
    public var status: String
    public var stage: String?
    public var ref: String?
    public var webUrl: String?
    public var commit: Commit?
    public var pipeline: GitLabPipeline?
    public var runner: Runner?
    public var finishedAt: String?

    public init(id: Int, name: String, status: String, stage: String? = nil, ref: String? = nil, webUrl: String? = nil,
                commit: Commit? = nil, pipeline: GitLabPipeline? = nil, runner: Runner? = nil, finishedAt: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.stage = stage
        self.ref = ref
        self.webUrl = webUrl
        self.commit = commit
        self.pipeline = pipeline
        self.runner = runner
        self.finishedAt = finishedAt
    }

    /// The commit the job ran.
    public var sha: String? { commit?.id ?? pipeline?.sha }

    public var finished: Date? {
        guard let finishedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: finishedAt) ?? ISO8601DateFormatter().date(from: finishedAt)
    }
}

extension GitLabJob.Commit {
    public init(id: String) {
        self.id = id
        title = nil
    }
}

extension GitLabJob.Runner {
    public init(description: String) {
        id = nil
        self.description = description
    }
}

public struct GitLabMergeRequest: Decodable, Sendable, Equatable {
    public var iid: Int
    public var title: String
    public var webUrl: String?
    public var headPipeline: GitLabPipeline?

    public init(iid: Int, title: String, webUrl: String? = nil, headPipeline: GitLabPipeline? = nil) {
        self.iid = iid
        self.title = title
        self.webUrl = webUrl
        self.headPipeline = headPipeline
    }
}

/// A pipeline's test report, from the JUnit files its jobs upload: one suite per job.
public struct CITestReport: Decodable, Sendable, Equatable {
    public struct Suite: Decodable, Sendable, Equatable {
        /// The job's name.
        public var name: String
        public var totalCount: Int?
        public var successCount: Int?
        public var skippedCount: Int?
        public var testCases: [Case]
    }

    public struct Case: Decodable, Sendable, Equatable {
        /// `success`, `failed`, `error` or `skipped`.
        public var status: String
        public var name: String
        /// `Bundle.Suite`, or just the suite, as the JUnit writer puts it.
        public var classname: String?
        /// The failure message, for a failed test.
        public var systemOutput: String?
        public var stackTrace: String?

        public var failed: Bool { status == "failed" || status == "error" }
        /// What the test reported: its failure message, else its stack trace.
        public var message: String { [systemOutput, stackTrace].compactMap { $0 }.first { !$0.isEmpty } ?? "" }
    }

    public var testSuites: [Suite]
}
