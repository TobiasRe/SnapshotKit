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

    public var path: String
    public var byteSize: Int
    public var state: State

    public var id: String { path }
    public var fileName: String { (path as NSString).lastPathComponent }

    /// The test target, e.g. `FeatureSnapshotTests`.
    public var module: String { SnapshotModules.module(forSnapshotPath: path) ?? "(no module)" }

    /// The test file the snapshot belongs to (the folder under `__Snapshots__`).
    public var suite: String {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.isEmpty ? "(root)" : parent
    }

    /// The test name: the file name up to the first dot.
    public var testName: String {
        let base = (fileName as NSString).deletingPathExtension
        return base.split(separator: ".", maxSplits: 1).first.map(String.init) ?? base
    }

    /// What tells this test's snapshots apart: a counter ("1") or a `named:` value ("dark").
    public var variant: String {
        let base = (fileName as NSString).deletingPathExtension
        let parts = base.split(separator: ".", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : ""
    }

    public init(path: String, byteSize: Int, state: State = .clean) {
        self.path = path
        self.byteSize = byteSize
        self.state = state
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
        self.files = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Tracked and untracked (not ignored) PNGs under any `__Snapshots__` folder.
    public static func load(repository: URL) throws -> SnapshotLibrary {
        let git = Git(root: repository)
        let pathspec = ":(glob)**/__Snapshots__/**/*.png"
        let listed = try git.run(["ls-files", "--cached", "--others", "--exclude-standard", "--", pathspec])
        // Untrimmed and NUL-separated: the first line's leading space is part of its status code.
        let status = (try? Shell.run(["git", "status", "--porcelain", "-z", "--untracked-files=all", "--", pathspec], in: repository).stdout) ?? ""
        var states: [String: SnapshotFile.State] = [:]
        for line in status.split(separator: "\0") where line.count > 3 {
            let code = line.prefix(2), path = String(line.dropFirst(3))
            states[path] = code == "??" ? .untracked : .modified
        }
        var seen = Set<String>()
        let files: [SnapshotFile] = listed.split(separator: "\n").compactMap { line in
            let path = String(line)
            guard seen.insert(path).inserted,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: repository.appendingPathComponent(path).path)
            else { return nil } // tracked but deleted in the working tree
            return SnapshotFile(path: path, byteSize: (attributes[.size] as? Int) ?? 0, state: states[path] ?? .clean)
        }
        return SnapshotLibrary(files: files)
    }

    public var totalBytes: Int { files.reduce(0) { $0 + $1.byteSize } }
    public var testCount: Int { Set(files.map { $0.module + "/" + $0.suite + "/" + $0.testName }).count }

    /// Module › suite › test › files, each level sorted by name.
    public static func tree(_ files: [SnapshotFile]) -> [SnapshotModule] {
        Dictionary(grouping: files, by: \.module).map { module, moduleFiles in
            let suites = Dictionary(grouping: moduleFiles, by: \.suite).map { suite, suiteFiles in
                let tests = Dictionary(grouping: suiteFiles, by: \.testName).map { name, testFiles in
                    SnapshotTest(module: module, suite: suite, name: name,
                                 files: testFiles.sorted { $0.variant.localizedStandardCompare($1.variant) == .orderedAscending })
                }
                return SnapshotSuite(module: module, name: suite, tests: tests.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
            return SnapshotModule(name: module, suites: suites.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
}
