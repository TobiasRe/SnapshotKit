import Foundation

public struct ProjectSettings: Codable, Equatable, Sendable {
    /// Overrides the auto-detected base branch.
    public var baseBranch: String?
    /// Overrides `remoteHost` from `.snapshotkit.yml` (hosts are often personal, not committed).
    public var remoteHost: String?
    /// The module picked in the run scope picker; nil means "what CI runs".
    public var module: String?

    public init(baseBranch: String? = nil, remoteHost: String? = nil, module: String? = nil) {
        self.baseBranch = baseBranch
        self.remoteHost = remoteHost
        self.module = module
    }
}

public struct Project: Codable, Hashable, Identifiable, Sendable {
    public var path: String
    public var name: String { (path as NSString).lastPathComponent }
    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    public init(path: String) {
        self.path = (path as NSString).standardizingPath
    }
}

/// Everything the app persists, stored as one JSON file.
public struct AppSettings: Codable, Equatable, Sendable {
    public var scanRoots: [String] = []
    public var discovered: [String] = []
    public var pinned: [String] = []
    /// Most recent first.
    public var recents: [String] = []
    public var projectSettings: [String: ProjectSettings] = [:]
    public var lastProject: String?
    public var flakeIterations: Int = 5
    public var verifyAfterRecord: Bool = true

    public init() {}

    /// Missing keys fall back to defaults, so older or hand-written settings files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        scanRoots = try c.decodeIfPresent([String].self, forKey: .scanRoots) ?? d.scanRoots
        discovered = try c.decodeIfPresent([String].self, forKey: .discovered) ?? d.discovered
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? d.pinned
        recents = try c.decodeIfPresent([String].self, forKey: .recents) ?? d.recents
        projectSettings = try c.decodeIfPresent([String: ProjectSettings].self, forKey: .projectSettings) ?? d.projectSettings
        lastProject = try c.decodeIfPresent(String.self, forKey: .lastProject)
        flakeIterations = try c.decodeIfPresent(Int.self, forKey: .flakeIterations) ?? d.flakeIterations
        verifyAfterRecord = try c.decodeIfPresent(Bool.self, forKey: .verifyAfterRecord) ?? d.verifyAfterRecord
    }
}

extension AppSettings {
    /// Paths in one canonical form (e.g. `/private/var/…` and `/var/…` are the same folder), without duplicates.
    func normalized() -> AppSettings {
        func norm(_ paths: [String]) -> [String] {
            var seen = Set<String>()
            return paths.map { Project(path: $0).path }.filter { seen.insert($0).inserted }
        }
        var s = self
        s.scanRoots = norm(scanRoots)
        s.discovered = norm(discovered)
        s.pinned = norm(pinned)
        s.recents = norm(recents)
        s.lastProject = lastProject.map { Project(path: $0).path }
        s.projectSettings = Dictionary(projectSettings.map { (Project(path: $0.key).path, $0.value) }, uniquingKeysWith: { a, _ in a })
        return s
    }
}

/// Loads and saves `AppSettings`, and answers project-list questions.
public final class ProjectStore: @unchecked Sendable {
    public static let maxRecents = 10
    public let url: URL
    private let lock = NSLock()
    private var cached: AppSettings

    public init(url: URL = SnapshotKitPaths.home.appendingPathComponent("settings.json")) {
        self.url = url
        cached = (Self.read(url) ?? AppSettings()).normalized()
    }

    public var settings: AppSettings { lock.withLock { cached } }

    public func update(_ change: (inout AppSettings) -> Void) {
        lock.withLock {
            change(&cached)
            Self.write(cached, to: url)
        }
    }

    // MARK: Projects

    /// Pinned first, then recents, then the rest of the discovered projects alphabetically.
    public var allProjects: [Project] {
        let s = settings
        var seen = Set<String>()
        var out: [Project] = []
        for path in s.pinned + s.recents + s.discovered.sorted(by: { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }) where seen.insert(path).inserted {
            out.append(Project(path: path))
        }
        return out
    }

    public func isPinned(_ project: Project) -> Bool { settings.pinned.contains(project.path) }

    public func togglePin(_ project: Project) {
        update { s in
            if let i = s.pinned.firstIndex(of: project.path) { s.pinned.remove(at: i) } else { s.pinned.append(project.path) }
        }
    }

    public func markOpened(_ project: Project) {
        update { s in
            s.recents.removeAll { $0 == project.path }
            s.recents.insert(project.path, at: 0)
            if s.recents.count > Self.maxRecents { s.recents.removeLast(s.recents.count - Self.maxRecents) }
            s.lastProject = project.path
            if !s.discovered.contains(project.path) { s.discovered.append(project.path) }
        }
    }

    public func remove(_ project: Project) {
        update { s in
            s.discovered.removeAll { $0 == project.path }
            s.recents.removeAll { $0 == project.path }
            s.pinned.removeAll { $0 == project.path }
            if s.lastProject == project.path { s.lastProject = nil }
        }
    }

    public func settings(for project: Project) -> ProjectSettings {
        settings.projectSettings[project.path] ?? ProjectSettings()
    }

    public func updateSettings(for project: Project, _ change: (inout ProjectSettings) -> Void) {
        update { s in
            var p = s.projectSettings[project.path] ?? ProjectSettings()
            change(&p)
            s.projectSettings[project.path] = p
        }
    }

    // MARK: Scan roots

    public func addScanRoot(_ path: String) {
        let p = (path as NSString).standardizingPath
        update { s in if !s.scanRoots.contains(p) { s.scanRoots.append(p) } }
    }

    public func removeScanRoot(_ path: String) {
        update { s in s.scanRoots.removeAll { $0 == path } }
    }

    /// Scans all roots and replaces the discovered list (pins and recents are kept).
    @discardableResult
    public func rescan() -> [Project] {
        let found = settings.scanRoots.flatMap { ProjectScanner.scan(root: URL(fileURLWithPath: $0)) }
        update { s in s.discovered = Array(Set(found.map(\.path) + s.recents + s.pinned)).sorted() }
        return found
    }

    // MARK: IO

    static func read(_ url: URL) -> AppSettings? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    static func write(_ settings: AppSettings, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(settings).write(to: url, options: .atomic)
    }
}

/// Finds git repositories with snapshot tests below a root folder.
public enum ProjectScanner {
    static let skipped: Set<String> = ["node_modules", "Pods", "Carthage", "DerivedData", ".build", "build", "vendor", "Library"]

    public static func scan(root: URL, maxDepth: Int = 4) -> [Project] {
        var found: [Project] = []
        let fm = FileManager.default
        func visit(_ dir: URL, depth: Int) {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                if hasSnapshotTests(dir) { found.append(Project(path: dir.path)) }
                return // do not descend into nested repositories
            }
            guard depth < maxDepth,
                  let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            else { return }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true, !skipped.contains(entry.lastPathComponent),
                      entry.pathExtension.isEmpty || !["app", "xcodeproj", "xcworkspace", "xcassets", "bundle", "framework"].contains(entry.pathExtension)
                else { continue }
                visit(entry, depth: depth + 1)
            }
        }
        visit(root.standardizedFileURL, depth: 0)
        return found.sorted { $0.path < $1.path }
    }

    /// True if the repository tracks a `__Snapshots__` file or has a `.snapshotkit.yml`.
    public static func hasSnapshotTests(_ repo: URL) -> Bool {
        if FileManager.default.fileExists(atPath: repo.appendingPathComponent(SnapshotConfig.overrideFileName).path) { return true }
        let result = try? Shell.run(["git", "ls-files", "--", ":(glob)**/__Snapshots__/**"], in: repo)
        return !(result?.trimmedOutput.isEmpty ?? true)
    }
}
