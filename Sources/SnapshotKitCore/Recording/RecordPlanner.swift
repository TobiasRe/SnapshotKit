import Foundation

/// What to record: the suites whose source gets the record trait, and the `-only-testing`
/// identifiers that limit the run to the chosen tests.
public struct RecordSelection: Sendable, Equatable {
    public var suites: [SuiteResult]
    public var onlyTesting: [String]

    public init(suites: [SuiteResult], onlyTesting: [String]) {
        self.suites = suites
        self.onlyTesting = onlyTesting
    }
}

/// Turns snapshots from the library into a record selection.
///
/// swift-snapshot-testing names a snapshot's folder after the test *file* and the file after the
/// test *function*, so this reads the test file to find the suite type and how to address the test.
public enum RecordPlanner {
    public enum Granularity: Sendable {
        /// Only the tests that produced the given snapshots.
        case tests
        /// Every test in the suites of the given snapshots.
        case suites
    }

    public static func plan(_ files: [SnapshotFile], granularity: Granularity, repository: URL) throws -> RecordSelection {
        var suites: [String: SuiteResult] = [:]
        var order: [String] = []
        var only: [String] = []
        let git = Git(root: repository)
        let swiftFiles = git.lsFiles(["*.swift"])
        for file in files {
            let source = try testFile(for: file, among: swiftFiles, repository: repository)
            guard let text = try? String(contentsOf: repository.appendingPathComponent(source), encoding: .utf8),
                  let suitePath = suitePath(in: text, preferring: file.suite) else {
                throw RecordPatchError.suiteFileNotFound("\(file.module)/\(file.suite)")
            }
            let suite = SuiteResult(bundle: file.module, path: suitePath, tests: [],
                                    failureFiles: [repository.appendingPathComponent(source).path])
            if suites[suite.identifier] == nil { order.append(suite.identifier) }
            suites[suite.identifier] = suite

            let isXCTest = RecordPatcher.findDeclaration(of: suite.name, in: text)?.isXCTest ?? false
            let id: String
            switch granularity {
            case .suites:
                id = suite.identifier
            case .tests:
                // A parameterized test's snapshot name ("name-label") can't be turned back into its
                // full identifier ("name(label:)"), so its whole suite runs instead.
                if file.testName.contains("-") || !text.contains("func \(file.testName)(") {
                    id = suite.identifier
                } else {
                    id = suite.identifier + "/" + file.testName + (isXCTest ? "" : "()")
                }
            }
            if !only.contains(id) { only.append(id) }
        }
        // A suite-level identifier already covers that suite's single tests.
        let suiteIDs = Set(only.filter { suites[$0] != nil })
        only = only.filter { id in suiteIDs.contains(id) || !suiteIDs.contains(where: { id.hasPrefix($0 + "/") }) }
        return RecordSelection(suites: order.compactMap { suites[$0] }, onlyTesting: only)
    }

    /// The test file: `<suite folder>.swift`, preferably next to the `__Snapshots__` folder.
    static func testFile(for file: SnapshotFile, among swiftFiles: [String], repository: URL) throws -> String {
        let snapshotsDir = file.path.components(separatedBy: "/__Snapshots__/").first ?? ""
        let name = file.suite + ".swift"
        let matches = swiftFiles.filter { ($0 as NSString).lastPathComponent == name }
        if let next = matches.first(where: { $0.hasPrefix(snapshotsDir + "/") }) { return next }
        if let any = matches.first { return any }
        throw RecordPatchError.suiteFileNotFound("\(file.module)/\(file.suite)")
    }

    /// The suite's path for `-only-testing`: the type named like the file if there is one, else the
    /// first test type in it; prefixed with the type an `extension` nests it in.
    static func suitePath(in source: String, preferring name: String) -> [String]? {
        let declared = typeNames(in: source)
        guard let suite = declared.first(where: { $0.name == name })
            ?? declared.first(where: { $0.name.hasSuffix("Tests") || $0.name.hasSuffix("Test") })
            ?? declared.first else { return nil }
        return suite.parent.map { [$0, suite.name] } ?? [suite.name]
    }

    private static let typeDecl = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:@[\w.]+(?:\([^\n]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final|open|package|nonisolated)\s+)*(?:struct|class|actor|enum)\s+(\w+)"#
    )
    private static let extensionDecl = try! NSRegularExpression(pattern: #"^extension\s+(\w+)"#)

    /// Types declared in a file, with the type of the enclosing `extension` for indented ones.
    static func typeNames(in source: String) -> [(name: String, parent: String?)] {
        var result: [(String, String?)] = []
        var currentExtension: String?
        for line in source.components(separatedBy: "\n") {
            let ns = line as NSString, range = NSRange(location: 0, length: ns.length)
            if let m = extensionDecl.firstMatch(in: line, range: range) {
                currentExtension = ns.substring(with: m.range(at: 1))
            } else if let m = typeDecl.firstMatch(in: line, range: range) {
                let indented = m.range(at: 1).length > 0
                result.append((ns.substring(with: m.range(at: 2)), indented ? currentExtension : nil))
            } else if line.hasPrefix("}") {
                currentExtension = nil
            }
        }
        return result
    }
}
