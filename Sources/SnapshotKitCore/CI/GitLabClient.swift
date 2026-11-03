import Foundation

/// Reads GitLab's REST API (`/api/v4/…`). Requests are read-only: SnapshotKit never changes anything on GitLab.
public protocol GitLabAPI: Sendable {
    /// The response body of `GET /api/v4/<path>`; `path` may carry a query.
    func get(_ path: String) throws -> Data
}

public enum GitLabError: Error, LocalizedError, Equatable {
    /// Neither `glab` nor a token can reach the host.
    case noAccess(host: String, detail: String)
    /// glab isn't installed, and no token is set.
    case glabMissing(host: String)
    /// GitLab didn't accept who SnapshotKit signed in as (401): glab signed out or expired, or the token rejected.
    /// `via` is `glab` or the token's variable.
    case unauthorized(host: String, via: String, detail: String)
    /// Signed in, but not allowed to read `path` (403).
    case forbidden(host: String, path: String, via: String)
    /// Nothing at `path` (404), or nothing the account can see.
    case notFound(path: String)
    /// The host didn't answer: DNS, network, VPN.
    case unreachable(host: String, detail: String)
    case request(path: String, output: String)
    /// What was pasted for a job names none.
    case notAJob(String, numbers: Bool)
    /// The job isn't in the project, or the account can't see it.
    case jobNotFound(id: Int, project: String, host: String)

    public var errorDescription: String? {
        switch self {
        case let .noAccess(host, detail):
            "SnapshotKit can’t reach the GitLab API on \(host) (\(detail)). Sign in with `glab auth login --hostname \(host)`, "
                + "or set GITLAB_TOKEN to an access token with read_api."
        case let .glabMissing(host):
            "SnapshotKit reads GitLab with the glab CLI or an access token, and has neither: glab isn’t installed (on the PATH, "
                + "in /opt/homebrew/bin or /usr/local/bin) and GITLAB_TOKEN isn’t set. Install glab (`brew install glab`) and sign in "
                + "with `glab auth login --hostname \(host)`, or set GITLAB_TOKEN to an access token with read_api in the environment "
                + "SnapshotKit starts in."
        case let .unauthorized(host, via, detail):
            via == "glab"
                ? "glab isn’t signed in to \(host), or its sign-in has expired (\(detail)). Sign in with `glab auth login --hostname \(host)`, "
                    + "or set GITLAB_TOKEN to an access token with read_api."
                : "GitLab on \(host) rejected \(via) (\(detail)): it may have expired or been revoked. Create a new access token with "
                    + "read_api, or sign in with `glab auth login --hostname \(host)` and unset \(via)."
        case let .forbidden(host, path, via):
            "GitLab on \(host) refused `\(path)` (403 Forbidden): the account \(via == "glab" ? "glab signs in with" : "of \(via)") "
                + "can’t read this project, or its token lacks the read_api scope."
        case let .notFound(path):
            "GitLab has nothing at `\(path)` (404 Not Found): it doesn’t exist, or the account SnapshotKit signs in with can’t see it."
        case let .unreachable(host, detail):
            "Can’t reach GitLab on \(host) (\(detail)). Check the network, and the VPN if \(host) needs one."
        case let .request(path, output):
            "GitLab answered `\(path)` with: \(output)"
        case let .notAJob(text, numbers):
            "“\(text)” isn’t a GitLab job’s URL (https://gitlab.example.com/group/project/-/jobs/123)" + (numbers ? ", nor a job number." : ".")
        case let .jobNotFound(id, project, host):
            "GitLab on \(host) has no job \(id) in \(project), or the account SnapshotKit signs in with can’t see it. Check the job’s "
                + "URL, and that glab or GITLAB_TOKEN signs in to an account with access to the project."
        }
    }

    /// Whether GitLab said there is nothing at the path (404).
    public var isNotFound: Bool {
        switch self {
        case .notFound, .jobNotFound: true
        case let .request(_, output): Self.contains(output, status: 404) || output.lowercased().contains("not found")
        default: false
        }
    }

    /// What a failed request's output says went wrong: signed out, not allowed, not there, no network, or else
    /// the output itself.
    public static func classify(path: String, output: String, host: String, via: String) -> GitLabError {
        let text = output.lowercased()
        let detail = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }.map { String($0.prefix(200)) } ?? output
        if contains(text, status: 401) || text.contains("unauthorized") || text.contains("not authenticated")
            || text.contains("glab auth login") || text.contains("invalid_token") || text.contains("token was revoked") {
            return .unauthorized(host: host, via: via, detail: detail)
        }
        if contains(text, status: 403) || text.contains("forbidden") || text.contains("insufficient_scope") {
            return .forbidden(host: host, path: path, via: via)
        }
        if contains(text, status: 404) || text.contains("not found") { return .notFound(path: path) }
        if ["could not resolve host", "failed to connect", "timed out", "no such host", "connection refused",
            "network is unreachable", "couldn't connect", "ssl certificate problem"].contains(where: text.contains) {
            return .unreachable(host: host, detail: detail)
        }
        return .request(path: path, output: detail)
    }

    private static func contains(_ text: String, status: Int) -> Bool {
        text.range(of: #"(?<![0-9])\#(status)(?![0-9])"#, options: .regularExpression) != nil
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
    /// Where the token came from, to name it in errors (never its value).
    var tokenVariable: String

    public init(host: String, token: String, variable: String = "GITLAB_TOKEN") {
        self.host = host
        self.token = token
        tokenVariable = variable
    }

    public func get(_ path: String) throws -> Data {
        let url = "https://\(host)/api/v4/\(path)"
        let result = try Shell.run(["curl", "-sS", "--fail-with-body", "-H", "@-", url], input: Data("PRIVATE-TOKEN: \(token)\n".utf8))
        guard result.succeeded else {
            throw GitLabError.classify(path: path, output: (result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines),
                                       host: host, via: tokenVariable)
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
        token = ["GITLAB_TOKEN", "GITLAB_PRIVATE_TOKEN"].lazy.compactMap { name in
            environment[name].flatMap { $0.isEmpty ? nil : TokenAPI(host: host, token: $0, variable: name) }
        }.first
    }

    public func get(_ path: String) throws -> Data {
        do {
            return try glab.get(path)
        } catch let error as CommandError {
            if let token { return try token.get(path) }
            if error.isNotFound { throw GitLabError.glabMissing(host: host) }
            let output = (error.result.stderr + "\n" + error.result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitLabError.classify(path: path, output: output.isEmpty ? "glab failed" : output, host: host, via: "glab")
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
