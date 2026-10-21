import Foundation

/// Finds the Swift file that declares a test suite.
public enum SuiteLocator {
    /// Where to switch record mode on for `suites`: each suite's type in the file that declares it,
    /// and for a suite without a path, the tests outside any type, in every file that declares them.
    public static func targets(for suites: [SuiteResult], in repository: URL) throws -> [RecordSession.Target] {
        try suites.flatMap { suite in
            suite.path.isEmpty
                ? try locateTopLevelTests(suite, in: repository).map { RecordSession.Target(suite: nil, path: $0) }
                : [RecordSession.Target(suite: suite.path, path: try locate(suite, in: repository))]
        }
    }

    /// The files with the tests of a suite without a path: `@Test` functions outside any type. Those
    /// that reported its failures, else every tracked Swift file that declares one of the tests to
    /// record (its failing ones, if any failed). Paths relative to the repository.
    static func locateTopLevelTests(_ suite: SuiteResult, in repository: URL) throws -> [String] {
        let root = URL.canonicalPath(repository.path)
        let names = Set(suite.testsToRecord.map(\.identifier))
        func declaresTests(_ path: String) -> Bool {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            let declared = RecordPatcher.topLevelTests(in: text).map(\.identifier)
            return names.isEmpty ? !declared.isEmpty : declared.contains(where: names.contains)
        }
        let reported = suite.failureFiles.map(URL.canonicalPath).filter { $0.hasPrefix(root + "/") && declaresTests($0) }
        let files = reported.isEmpty && !names.isEmpty
            ? Git(root: repository).lsFiles(["*.swift"]).map { root + "/" + $0 }.filter(declaresTests)
            : reported
        guard !files.isEmpty else { throw RecordPatchError.suiteFileNotFound(suite.identifier) }
        return files.map { String($0.dropFirst(root.count + 1)) }
    }

    /// Uses failure locations from the result bundle first, then searches tracked Swift files.
    /// Returns a path relative to the repository.
    public static func locate(_ suite: SuiteResult, in repository: URL) throws -> String {
        let root = URL.canonicalPath(repository.path)
        for file in suite.failureFiles {
            let path = URL.canonicalPath(file)
            guard path.hasPrefix(root + "/"), let text = try? String(contentsOfFile: path, encoding: .utf8),
                  RecordPatcher.findDeclaration(of: suite.path, in: text) != nil else { continue }
            return String(path.dropFirst(root.count + 1))
        }
        let git = Git(root: repository)
        let candidates = git.lsFiles(["*.swift"]).filter { path in
            guard let text = try? String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8) else { return false }
            return RecordPatcher.findDeclaration(of: suite.path, in: text) != nil
        }
        // Prefer files inside the suite's test bundle directory.
        if let inBundle = candidates.first(where: { $0.split(separator: "/").contains(Substring(suite.bundle)) }) {
            return inBundle
        }
        if let first = candidates.first { return first }
        throw RecordPatchError.suiteFileNotFound(suite.identifier)
    }
}
