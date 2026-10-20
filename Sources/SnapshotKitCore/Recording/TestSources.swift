import Foundation

/// A repository's Swift files for finding the tests behind snapshots, each file read at most once:
/// the library asks about thousands of snapshots, most of them in the same few test files.
final class TestSources {
    let repository: URL
    /// Tracked Swift files by file name ("CardTests.swift" → every path with that name).
    private let pathsByName: [String: [String]]
    private var texts: [String: String?] = [:]
    /// How many files were read, for tests.
    private(set) var reads = 0

    init(repository: URL) {
        self.repository = repository
        pathsByName = Dictionary(grouping: Git(root: repository).lsFiles(["*.swift"])) { ($0 as NSString).lastPathComponent }
    }

    /// The test file of a snapshot: `<suite folder>.swift`, preferably next to the `__Snapshots__` folder.
    func testFile(for file: SnapshotFile) throws -> String {
        let matches = pathsByName[file.suite + ".swift"] ?? []
        let snapshotsDir = file.path.components(separatedBy: "/__Snapshots__/").first ?? ""
        guard let path = matches.first(where: { $0.hasPrefix(snapshotsDir + "/") }) ?? matches.first else {
            throw RecordPatchError.suiteFileNotFound("\(file.module)/\(file.suite)")
        }
        return path
    }

    /// The file's text, or nil when it can't be read.
    func text(of path: String) -> String? {
        if let text = texts[path] { return text }
        reads += 1
        let text = try? String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
        texts[path] = text
        return text
    }
}
