import Foundation
@testable import SnapshotKitCore

/// A throwaway git repository for tests.
struct TempRepo {
    let url: URL
    var git: Git { Git(root: url) }

    init(branch: String = "develop") throws {
        url = testTemp("repo")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", branch])
        // Written rather than set with three more `git config` runs: a few hundred repositories
        // are made per test run.
        let config = try FileHandle(forWritingTo: url.appendingPathComponent(".git/config"))
        defer { try? config.close() }
        try config.seekToEnd()
        try config.write(contentsOf: Data("[user]\n\temail = tests@example.com\n\tname = Tests\n[commit]\n\tgpgsign = false\n".utf8))
    }

    func write(_ path: String, _ text: String) throws {
        try write(path, Data(text.utf8))
    }

    func write(_ path: String, _ data: Data) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    func commitAll(_ message: String) throws {
        try git.run(["add", "-A"])
        try git.run(["commit", "-q", "-m", message])
    }
}

/// A fresh path for one test's files. Everything lives under one directory per test process;
/// directories of processes that have finished are removed, so test runs don't pile up.
func testTemp(_ name: String) -> URL {
    TestTemp.root.appendingPathComponent("\(name)-\(UUID().uuidString)").resolvingSymlinksInPath()
}

enum TestTemp {
    /// Also isolates the test process, once: settings, history and the patch registry go to a
    /// temporary home instead of the user's, and git ignores the user's and the system's
    /// configuration (hooks, signing or `core.quotePath` would change what the tests see).
    static let root: URL = {
        let runs = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-test-runs")
        for old in (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? [] {
            if let pid = Int32(old), pid != getpid(), kill(pid, 0) == 0 { continue }
            try? FileManager.default.removeItem(at: runs.appendingPathComponent(old))
        }
        let root = runs.appendingPathComponent("\(getpid())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("SNAPSHOTKIT_HOME", root.appendingPathComponent("home").path, 1)
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        return root
    }()
}
