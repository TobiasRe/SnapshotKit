import Foundation

/// The failed CI jobs of the checked-out branch: its open merge request's latest pipeline.
public struct CIDetection: Sendable, Equatable {
    public var project: GitLabLink
    public var branch: String
    public var mergeRequest: GitLabMergeRequest
    public var pipeline: GitLabPipeline
    public var failedJobs: [GitLabJob]

    public init(project: GitLabLink, branch: String, mergeRequest: GitLabMergeRequest, pipeline: GitLabPipeline, failedJobs: [GitLabJob]) {
        self.project = project
        self.branch = branch
        self.mergeRequest = mergeRequest
        self.pipeline = pipeline
        self.failedJobs = failedJobs
    }

    /// Each failed job's link, to load it.
    public func link(to job: GitLabJob) -> GitLabLink {
        GitLabLink(host: project.host, projectPath: project.projectPath, jobID: job.id)
    }
}

public enum CIDetector {
    /// The GitLab project of the repository's `origin`, if it is one GitLab can be asked about.
    public static func project(of repository: URL) -> GitLabLink? {
        Git(root: repository).tryRun(["remote", "get-url", "origin"]).flatMap(GitLabLink.remote)
    }

    /// The job `text` names: its URL, or its number in the repository's GitLab project.
    public static func job(_ text: String, repository: URL) throws -> GitLabLink {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = GitLabLink.job(url: text) { return link }
        if let id = Int(text.drop { $0 == "#" }), var project = project(of: repository) {
            project.jobID = id
            return project
        }
        throw GitLabError.notAJob(text, numbers: project(of: repository) != nil)
    }

    /// The failed jobs of the branch's open merge request, nil when there is no such request or nothing failed
    /// in its latest pipeline. `api` is made for the remote's host.
    public static func detect(repository: URL, api: (String) -> GitLabAPI = { DefaultGitLabAPI(host: $0) }) throws -> CIDetection? {
        guard let project = project(of: repository), let branch = Git(root: repository).currentBranch() else { return nil }
        let gitlab = api(project.host)
        // The newest request from the branch; its own page has its latest pipeline.
        guard let listed = try gitlab.openMergeRequests(from: branch, in: project).max(by: { $0.iid < $1.iid }) else { return nil }
        let request = try gitlab.mergeRequest(listed.iid, in: project)
        guard let pipeline = request.headPipeline else { return nil }
        let failed = try gitlab.failedJobs(ofPipeline: pipeline.id, in: project).sorted { $0.id < $1.id }
        guard !failed.isEmpty else { return nil }
        return CIDetection(project: project, branch: branch, mergeRequest: request, pipeline: pipeline, failedJobs: failed)
    }
}
