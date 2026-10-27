import Foundation

/// The outcome of reading a repository's CI files and `.snapshotkit.yml`.
public struct ResolvedConfig: Sendable {
    public var repository: URL
    public var config: SnapshotConfig
    /// CI files that were read, relative to the repository.
    public var ciFiles: [String]
    public var overrideFile: String?
    public var notes: [String]

    public init(repository: URL, config: SnapshotConfig, ciFiles: [String], overrideFile: String?, notes: [String]) {
        self.repository = repository
        self.config = config
        self.ciFiles = ciFiles
        self.overrideFile = overrideFile
        self.notes = notes
    }
}

public enum ConfigResolver {
    /// Reads CI definitions and the override file. Does not touch Xcode or simulators;
    /// see `EnvironmentValidator` for that.
    public static func resolve(repository: URL) throws -> ResolvedConfig {
        let fm = FileManager.default
        var documents: [CIConfigParser.Document] = []
        var notes: [String] = []

        func read(_ relative: String) -> CIConfigParser.Document? {
            let url = repository.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return .init(name: relative, text: text)
        }

        if let gitlab = read(".gitlab-ci.yml") {
            documents.append(gitlab)
            // Local includes: `include: - local: path/to/file.yml` or `include: path.yml`.
            let regex = try NSRegularExpression(pattern: #"(?:local:\s*|include:\s*)['"]?/?([A-Za-z0-9_./-]+\.ya?ml)"#)
            let ns = gitlab.text as NSString
            for m in regex.matches(in: gitlab.text, range: NSRange(location: 0, length: ns.length)) {
                let path = ns.substring(with: m.range(at: 1))
                if !documents.contains(where: { $0.name == path }), let doc = read(path) { documents.append(doc) }
            }
        }
        let workflows = repository.appendingPathComponent(".github/workflows")
        if let entries = try? fm.contentsOfDirectory(atPath: workflows.path) {
            for entry in entries.sorted() where entry.hasSuffix(".yml") || entry.hasSuffix(".yaml") {
                if let doc = read(".github/workflows/\(entry)") { documents.append(doc) }
            }
        }
        let ciFiles = documents.map(\.name)

        // Scripts called from CI (when CI itself has no xcodebuild line).
        var extraction = CIConfigParser.extract(from: documents)
        if extraction.invocation == nil {
            var withScripts = documents
            for doc in documents {
                for script in CIConfigParser.referencedScripts(in: doc.text) where !withScripts.contains(where: { $0.name == script }) {
                    if let s = read(script) { withScripts.append(s) }
                }
            }
            if withScripts.count > documents.count {
                extraction = CIConfigParser.extract(from: withScripts)
            }
        }
        notes += extraction.notes
        var config = extraction.config
        if documents.isEmpty { notes.append("No .gitlab-ci.yml or .github/workflows found; using \(SnapshotConfig.overrideFileName) only.") }

        var overrideFile: String?
        let overrideURL = repository.appendingPathComponent(SnapshotConfig.overrideFileName)
        if let text = try? String(contentsOf: overrideURL, encoding: .utf8) {
            do {
                let (override, unknown, mistyped) = try SnapshotConfig.fromOverrideFile(text)
                config.override(with: override)
                overrideFile = SnapshotConfig.overrideFileName
                if !unknown.isEmpty {
                    notes.append("Ignored unknown keys in \(SnapshotConfig.overrideFileName): \(unknown.joined(separator: ", "))")
                }
                if !mistyped.isEmpty {
                    notes.append("Ignored lists in \(SnapshotConfig.overrideFileName) where one value belongs: \(mistyped.joined(separator: ", "))")
                }
            } catch {
                throw ConfigError.invalidOverride(error.localizedDescription)
            }
        }

        if config.baseBranch == nil, let detected = detectBaseBranch(repository: repository) {
            config.baseBranch = detected
            config.sources[SnapshotConfig.Field.baseBranch.rawValue] = "git (auto-detected)"
        }
        locateNamedProjectFile(&config, repository: repository, notes: &notes)
        if config.project == nil && config.workspace == nil {
            if let found = discoverProjectFile(repository: repository, workingDirectory: config.workingDirectory) {
                if found.hasSuffix(".xcworkspace") { config.workspace = found } else { config.project = found }
                config.sources[(found.hasSuffix(".xcworkspace") ? SnapshotConfig.Field.workspace : .project).rawValue] = "found in repository"
            }
        }
        return ResolvedConfig(repository: repository, config: config, ciFiles: ciFiles, overrideFile: overrideFile, notes: notes)
    }

    /// `origin/HEAD`, else the first of develop/main/master that exists.
    public static func detectBaseBranch(repository: URL) -> String? {
        let git = Git(root: repository)
        if let remote = git.remoteDefaultBranch() { return remote }
        for candidate in ["develop", "main", "master"] where git.refExists(candidate) || git.refExists("origin/\(candidate)") {
            return candidate
        }
        return nil
    }

    /// CI can name the workspace or project without the folder its tests run in: `XCODE_PROJECT: App.xcodeproj`
    /// for a template elsewhere that changes into `Example/` first. When it isn't where the tests would run, and
    /// one folder of the repository has it, they run there; in several, a note says why the build may not find it.
    static func locateNamedProjectFile(_ config: inout SnapshotConfig, repository: URL, notes: inout [String]) {
        guard let name = config.workspace ?? config.project, !name.hasPrefix("/"), !name.contains("$") else { return }
        let directory = config.workingDirectory.map { repository.appendingPathComponent($0) } ?? repository
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else { return }
        let folders = foldersHolding(name, in: repository)
        if folders.count == 1 {
            config.workingDirectory = folders[0].isEmpty ? nil : folders[0]
            config.sources[SnapshotConfig.Field.workingDirectory.rawValue] = "where \(name) is"
        } else if folders.count > 1 {
            let named = folders.map { $0.isEmpty ? "the root" : $0 }
            let places = named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1]
            notes.append("CI names \(name), which is in \(places); it doesn’t say which "
                         + "folder its tests run in, so they run in the repository’s root.")
        }
    }

    /// The folders, relative to the repository ("" for its root), that hold `name` (itself a path like
    /// `App.xcodeproj` or `ios/App.xcodeproj`), sorted. Build output, dependencies and the insides of projects
    /// aren't searched.
    static func foldersHolding(_ name: String, in repository: URL, maxDepth: Int = 6) -> [String] {
        let skipped: Set<String> = [".build", "build", "DerivedData", "Pods", "Carthage", "node_modules", "vendor"]
        let root = repository.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: repository, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var folders: [String] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            let relative = String(path.dropFirst(root.count + 1))
            if skipped.contains(url.lastPathComponent) || ["xcodeproj", "xcworkspace"].contains(url.pathExtension) {
                enumerator.skipDescendants()
            }
            if enumerator.level > maxDepth { enumerator.skipDescendants() }
            if relative == name {
                folders.append("")
            } else if relative.hasSuffix("/" + name) {
                folders.append(String(relative.dropLast(name.count + 1)))
            }
        }
        return folders.sorted()
    }

    /// A single top-level workspace or project, if there is exactly one obvious choice.
    /// Swift packages need neither, so this returns nil when a Package.swift is present.
    static func discoverProjectFile(repository: URL, workingDirectory: String?) -> String? {
        let dir = workingDirectory.map { repository.appendingPathComponent($0) } ?? repository
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        if entries.contains("Package.swift") && !entries.contains(where: { $0.hasSuffix(".xcodeproj") }) { return nil }
        let workspaces = entries.filter { $0.hasSuffix(".xcworkspace") }
        if workspaces.count == 1 { return workspaces[0] }
        let projects = entries.filter { $0.hasSuffix(".xcodeproj") }
        if projects.count == 1 { return projects[0] }
        return nil
    }
}

public enum ConfigError: Error, LocalizedError, Equatable {
    case invalidOverride(String)
    case missingScheme

    public var errorDescription: String? {
        switch self {
        case .invalidOverride(let message):
            "`\(SnapshotConfig.overrideFileName)` could not be read (\(message))."
        case .missingScheme:
            "No scheme found. CI files do not contain an `xcodebuild -scheme …` call; add `scheme: <Name>` to `\(SnapshotConfig.overrideFileName)`."
        }
    }
}
