import Foundation

/// A repository plus its resolved configuration with per-project overrides applied.
/// Shared by the app and the CLI so both behave identically.
public struct ProjectContext: Sendable {
    public var repository: URL
    public var resolved: ResolvedConfig
    public var settings: ProjectSettings

    public init(repository: URL, resolved: ResolvedConfig, settings: ProjectSettings = ProjectSettings()) {
        self.repository = repository
        self.resolved = resolved
        self.settings = settings
    }

    /// The configuration actually used: CI → .snapshotkit.yml → per-project settings.
    public var config: SnapshotConfig {
        var config = resolved.config
        if let base = settings.baseBranch, !base.isEmpty {
            config.baseBranch = base
            config.sources[SnapshotConfig.Field.baseBranch.rawValue] = "project setting"
        }
        if let host = settings.remoteHost, !host.isEmpty {
            config.remoteHost = host
            config.sources[SnapshotConfig.Field.remoteHost.rawValue] = "project setting"
        }
        if let module = settings.module, !module.isEmpty {
            config.onlyTesting = [module]
            config.sources[SnapshotConfig.Field.onlyTesting.rawValue] = "module picker"
        }
        return config
    }

    public var baseBranch: String? { config.baseBranch }

    public static func load(repository: URL, settings: ProjectSettings = ProjectSettings()) throws -> ProjectContext {
        let root = Git.repository(containing: repository)?.root ?? repository
        return ProjectContext(repository: root, resolved: try ConfigResolver.resolve(repository: root), settings: settings)
    }

    /// Snapshot test targets found in the repository, for the module picker.
    public func modules() -> [String] {
        SnapshotModules.detect(in: Git(root: repository))
    }
}
