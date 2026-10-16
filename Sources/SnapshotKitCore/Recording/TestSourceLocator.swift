import Foundation

/// Where a snapshot's test is written: the source file and the line of its test function.
public struct TestSourceLocation: Equatable, Sendable {
    /// Repository-relative path of the test file.
    public var path: String
    /// One-based line of `func <test>(`, if it was found.
    public var line: Int?
}

public enum TestSourceLocator {
    /// Finds the test behind a snapshot: `<suite>.swift` (preferably next to its `__Snapshots__`
    /// folder), and in it the function named like the snapshot's test. Nil when there is no such file.
    public static func locate(_ file: SnapshotFile, in repository: URL) -> TestSourceLocation? {
        let swiftFiles = Git(root: repository).lsFiles(["*.swift"])
        guard let path = try? RecordPlanner.testFile(for: file, among: swiftFiles, repository: repository) else { return nil }
        let source = (try? String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)) ?? ""
        return TestSourceLocation(path: path, line: line(ofTest: file.testName, in: source))
    }

    /// The line of `func name(` (or of a parameterized test's function, whose snapshots are named
    /// "function-label").
    static func line(ofTest name: String, in source: String) -> Int? {
        let function = name.split(separator: "-").first.map(String.init) ?? name
        for (index, line) in source.components(separatedBy: "\n").enumerated()
        where line.contains("func \(function)(") || line.contains("func `\(function)`(") {
            return index + 1
        }
        return nil
    }
}
