import Foundation

/// A GitLab project, or one of its jobs, as a job's URL or a repository's git remote names it.
public struct GitLabLink: Equatable, Sendable {
    /// `gitlab.example.com`, with a port when it has one.
    public var host: String
    /// `group/subgroup/project`.
    public var projectPath: String
    public var jobID: Int?

    public init(host: String, projectPath: String, jobID: Int? = nil) {
        self.host = host
        self.projectPath = projectPath
        self.jobID = jobID
    }

    /// How the API names the project: its path, URL-encoded (`group%2Fproject`).
    public var projectID: String {
        projectPath.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? projectPath
    }

    /// The job's page, `https://host/group/project/-/jobs/123`.
    public var jobURL: String? { jobID.map { "https://\(host)/\(projectPath)/-/jobs/\($0)" } }

    /// A job's page as GitLab links it: `https://host/group/project/-/jobs/123`, also with a trailing
    /// path (`/raw`), query or fragment, and without the scheme.
    public static func job(url: String) -> GitLabLink? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        text = String(text.prefix { $0 != "?" && $0 != "#" })
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let dash = parts.firstIndex(of: "-"), dash >= 2, parts.count > dash + 2, parts[dash + 1] == "jobs",
              let id = Int(parts[dash + 2]) else { return nil }
        return GitLabLink(host: parts[0], projectPath: parts[1..<dash].joined(separator: "/"), jobID: id)
    }

    /// The project a git remote points at: `git@host:group/project.git`, `ssh://git@host:2222/group/project.git`,
    /// or `https://host/group/project.git`. An SSH remote's host is taken as the web host too, as is usual.
    public static func remote(_ remote: String) -> GitLabLink? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String, path: String
        if let scheme = text.range(of: "://") {
            let isSSH = text.hasPrefix("ssh://") || text.hasPrefix("git+ssh://")
            text = String(text[scheme.upperBound...])
            guard let slash = text.firstIndex(of: "/") else { return nil }
            var authority = String(text[..<slash])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            // An SSH port isn't the web server's.
            if isSSH, let colon = authority.firstIndex(of: ":") { authority = String(authority[..<colon]) }
            host = authority
            path = String(text[text.index(after: slash)...])
        } else if let colon = text.firstIndex(of: ":") {      // scp-like: git@host:group/project.git
            var authority = String(text[..<colon])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            host = authority
            path = String(text[text.index(after: colon)...])
        } else {
            return nil
        }
        var project = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if project.hasSuffix(".git") { project.removeLast(4) }
        guard !host.isEmpty, project.contains("/") else { return nil }
        return GitLabLink(host: host, projectPath: project)
    }
}
