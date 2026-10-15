import Foundation

/// Finds the Swift file that declares a test suite.
public enum SuiteLocator {
    /// Uses failure locations from the result bundle first, then searches tracked Swift files.
    /// Returns a path relative to the repository.
    public static func locate(_ suite: SuiteResult, in repository: URL) throws -> String {
        let root = URL.canonicalPath(repository.path)
        for file in suite.failureFiles {
            let path = URL.canonicalPath(file)
            guard path.hasPrefix(root + "/"), let text = try? String(contentsOfFile: path, encoding: .utf8),
                  RecordPatcher.findDeclaration(of: suite.name, in: text) != nil else { continue }
            return String(path.dropFirst(root.count + 1))
        }
        let git = Git(root: repository)
        let candidates = git.lsFiles(["*.swift"]).filter { path in
            guard let text = try? String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8) else { return false }
            return RecordPatcher.findDeclaration(of: suite.name, in: text) != nil
        }
        // Prefer files inside the suite's test bundle directory.
        if let inBundle = candidates.first(where: { $0.split(separator: "/").contains(Substring(suite.bundle)) }) {
            return inBundle
        }
        if let first = candidates.first { return first }
        throw RecordPatchError.suiteFileNotFound(suite.identifier)
    }
}
