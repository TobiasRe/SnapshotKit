import Foundation

/// One reference image in the working tree, as swift-snapshot-testing lays them out:
/// `<Module>/…/__Snapshots__/<TestFile>/<test>.<name or counter>.png`.
public struct SnapshotFile: Identifiable, Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        /// Same as the last commit.
        case clean
        /// Changed in the working tree (for example just re-recorded).
        case modified
        /// Not tracked by git yet (a newly recorded snapshot).
        case untracked
    }

    public var path: String {
        didSet { if path != oldValue { parts = Parts(path) } }
    }
    public var byteSize: Int
    public var state: State
    /// When the file last changed on disk.
    public var modified: Date?

    /// Module, suite, test and variant, parsed once: the library groups and sorts thousands of
    /// files by them on every redraw.
    private var parts: Parts

    public var id: String { path }
    public var fileName: String { parts.fileName }

    /// The test target, e.g. `FeatureSnapshotTests`.
    public var module: String { parts.module }

    /// The test file the snapshot belongs to (the folder under `__Snapshots__`).
    public var suite: String { parts.suite }

    /// The test name: the file name up to the first dot.
    public var testName: String { parts.testName }

    /// What tells this test's snapshots apart: a counter ("1") or a `named:` value ("dark").
    public var variant: String { parts.variant }

    public init(path: String, byteSize: Int, state: State = .clean, modified: Date? = nil) {
        self.path = path
        self.byteSize = byteSize
        self.state = state
        self.modified = modified
        self.parts = Parts(path)
    }

    private struct Parts: Hashable, Sendable {
        var fileName, module, suite, testName, variant: String

        init(_ path: String) {
            fileName = (path as NSString).lastPathComponent
            module = SnapshotModules.module(forSnapshotPath: path) ?? "(no module)"
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            suite = parent.isEmpty ? "(root)" : parent
            let base = (fileName as NSString).deletingPathExtension
            let split = base.split(separator: ".", maxSplits: 1)
            testName = split.first.map(String.init) ?? base
            variant = split.count > 1 ? String(split[1]) : ""
        }
    }

    // Identity is the file and what's known about it; the parsed parts follow from the path.
    public static func == (a: SnapshotFile, b: SnapshotFile) -> Bool {
        a.path == b.path && a.byteSize == b.byteSize && a.state == b.state && a.modified == b.modified
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(byteSize)
        hasher.combine(state)
        hasher.combine(modified)
    }
}

/// Every snapshot of a test, e.g. `payButton.light.png` and `payButton.dark.png`.
public struct SnapshotTest: Identifiable, Hashable, Sendable {
    public var module: String
    public var suite: String
    public var name: String
    public var files: [SnapshotFile]
    public var id: String { module + "/" + suite + "/" + name }
}

public struct SnapshotSuite: Identifiable, Hashable, Sendable {
    public var module: String
    public var name: String
    public var tests: [SnapshotTest]
    public var id: String { module + "/" + name }
    public var fileCount: Int { tests.reduce(0) { $0 + $1.files.count } }
}

public struct SnapshotModule: Identifiable, Hashable, Sendable {
    public var name: String
    public var suites: [SnapshotSuite]
    public var id: String { name }
    public var fileCount: Int { suites.reduce(0) { $0 + $1.fileCount } }
}

/// All snapshot images in a repository's working tree, for browsing and managing them.
public struct SnapshotLibrary: Sendable {
    public var files: [SnapshotFile]

    public init(files: [SnapshotFile]) {
        self.files = files.sorted { Self.ordered($0.path, $1.path) }
    }

    /// The git pathspec for snapshot images: PNGs under a `__Snapshots__` folder, where
    /// swift-snapshot-testing writes them. Other PNGs (app icons, test fixtures) are not snapshots.
    public static let pathspec = ":(glob)**/__Snapshots__/**/*.png"

    /// Tracked and untracked (not ignored) PNGs under any `__Snapshots__` folder.
    public static func load(repository: URL) throws -> SnapshotLibrary {
        let git = Git(root: repository)
        let listed = try git.nulSeparated(["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", pathspec])
        var states: [String: SnapshotFile.State] = [:]
        for entry in (try? git.status(paths: [pathspec])) ?? [] {
            states[entry.path] = entry.code == "??" ? .untracked : .modified
        }
        var seen = Set<String>()
        let files: [SnapshotFile] = listed.compactMap { path in
            guard seen.insert(path).inserted,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: repository.appendingPathComponent(path).path)
            else { return nil } // tracked but deleted in the working tree
            return SnapshotFile(path: path, byteSize: (attributes[.size] as? Int) ?? 0, state: states[path] ?? .clean,
                                modified: attributes[.modificationDate] as? Date)
        }
        return SnapshotLibrary(files: files)
    }

    public var totalBytes: Int { files.reduce(0) { $0 + $1.byteSize } }
    public var testCount: Int { Set(files.map { $0.module + "/" + $0.suite + "/" + $0.testName }).count }

    /// Module › suite › test › files, each level sorted by name (numbers in natural order, so
    /// `test2` before `test10`).
    public static func tree(_ files: [SnapshotFile]) -> [SnapshotModule] {
        Dictionary(grouping: files, by: \.module).map { module, moduleFiles in
            let suites = Dictionary(grouping: moduleFiles, by: \.suite).map { suite, suiteFiles in
                let tests = Dictionary(grouping: suiteFiles, by: \.testName).map { name, testFiles in
                    SnapshotTest(module: module, suite: suite, name: name,
                                 files: testFiles.count < 2 ? testFiles : testFiles.sorted { ordered($0.variant, $1.variant) })
                }
                return SnapshotSuite(module: module, name: suite, tests: tests.sorted { ordered($0.name, $1.name) })
            }
            return SnapshotModule(name: module, suites: suites.sorted { ordered($0.name, $1.name) })
        }
        .sorted { ordered($0.name, $1.name) }
    }

    /// Finder-like order: case-insensitive, numbers by value (measured faster than a plain
    /// `compare(options: [.caseInsensitive, .numeric])` here). Every list of snapshots uses it,
    /// so the library and the Changes list agree.
    static func ordered(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    /// Case-insensitive, all words must appear in the path.
    public static func filter(_ files: [SnapshotFile], text: String) -> [SnapshotFile] {
        let terms = text.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return files }
        return files.filter { file in
            let haystack = file.path.lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    /// Snapshots whose test is gone: no `<suite>.swift` test file, or no function with the test's
    /// name in it. Leftovers of renamed or deleted tests that nothing records or checks any more.
    public static func orphans(_ files: [SnapshotFile], repository: URL) -> Set<String> {
        orphans(files, sources: TestSources(repository: repository))
    }

    static func orphans(_ files: [SnapshotFile], sources: TestSources) -> Set<String> {
        var functions: [String: [String]?] = [:]   // test file path → its functions (nil if unreadable)
        var orphans = Set<String>()
        for file in files {
            guard let path = try? sources.testFile(for: file) else {
                orphans.insert(file.id)
                continue
            }
            if functions[path] == nil {
                functions[path] = .some(sources.text(of: path).map { TestSourceLocator.functions(in: $0).map(\.name) })
            }
            guard let declared = functions[path] ?? nil else { continue }
            if !declared.contains(where: { TestSourceLocator.isFunction($0, ofTest: file.testName) }) { orphans.insert(file.id) }
        }
        return orphans
    }
}

extension SnapshotLibrary {
    /// "48.2 MB", and "0 KB" rather than "Zero KB".
    public static func formatSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
