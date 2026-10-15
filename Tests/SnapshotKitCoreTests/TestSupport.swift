import Foundation
@testable import SnapshotKitCore

/// A throwaway git repository for tests.
struct TempRepo {
    let url: URL
    var git: Git { Git(root: url) }

    init(branch: String = "develop") throws {
        isolateHome()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapkit-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", branch])
        try git.run(["config", "user.email", "tests@example.com"])
        try git.run(["config", "user.name", "Tests"])
        try git.run(["config", "commit.gpgsign", "false"])
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

/// Keeps tests from touching the user's real settings/registry.
func isolateHome() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-tests-home")
    setenv("SNAPSHOTKIT_HOME", dir.path, 1)
}

