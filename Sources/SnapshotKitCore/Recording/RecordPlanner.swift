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
        try plan(files, granularity: granularity, sources: TestSources(repository: repository))
    }

    static func plan(_ files: [SnapshotFile], granularity: Granularity, sources: TestSources) throws -> RecordSelection {
        var suites: [String: SuiteResult] = [:]
        var order: [String] = []
        var only: [String] = [], listed = Set<String>()
        // A suite's snapshots share its test file, which is parsed once for all of them.
        var parsed: [String: (text: String, suite: SuiteResult?, isXCTest: Bool, topLevelTests: [String])] = [:]
        var nested: [String: Bool] = [:]   // "<key>#<test>" → declared in a type inside the suite
        // A suite in two files (the target's tests outside a type, a type and its extension) has both.
        func add(_ suite: SuiteResult) {
            guard let known = suites[suite.identifier] else {
                order.append(suite.identifier)
                suites[suite.identifier] = suite
                return
            }
            suites[suite.identifier]!.failureFiles += suite.failureFiles.filter { !known.failureFiles.contains($0) }
        }
        for file in files {
            let source = try sources.testFile(for: file)
            let key = file.module + "/" + source
            let path = sources.repository.appendingPathComponent(source).path
            if parsed[key] == nil {
                guard let text = sources.text(of: source) else { throw RecordPatchError.suiteFileNotFound("\(file.module)/\(file.suite)") }
                let suite = suitePath(in: text, preferring: file.suite).map { SuiteResult(bundle: file.module, path: $0, tests: [], failureFiles: [path]) }
                parsed[key] = (text, suite, suite.flatMap { RecordPatcher.findDeclaration(of: $0.path, in: text)?.isXCTest } ?? false,
                               RecordPatcher.topLevelTests(in: text).map(\.identifier))
            }
            let (text, typeSuite, isXCTest, topLevelTests) = parsed[key]!

            // A test outside any type. The target's such tests are its suite without a path, whose
            // tests run one by one: the target's identifier would run all of its tests.
            let topLevel = topLevelTests.first { Self.snapshotName(ofTest: $0) == file.testName }
            guard let suite = typeSuite, topLevel == nil else {
                guard !topLevelTests.isEmpty else { throw RecordPatchError.suiteFileNotFound("\(file.module)/\(file.suite)") }
                add(SuiteResult(bundle: file.module, path: [], tests: [], failureFiles: [path]))
                let tests = granularity == .tests ? topLevel.map { [$0] } ?? topLevelTests : topLevelTests
                for id in tests.map({ file.module + "/" + $0 }) where listed.insert(id).inserted { only.append(id) }
                continue
            }
            add(suite)

            let id: String
            switch granularity {
            case .suites:
                id = suite.identifier
            case .tests:
                // A parameterized test's snapshot name ("name-label") can't be turned back into its
                // full identifier ("name(label:)"), so its whole suite runs instead. So does a test of
                // a suite nested in the file's suite: its identifier goes through that suite.
                let test = key + "#" + file.testName
                if !file.testName.contains("-"), text.contains("func \(file.testName)("), nested[test] == nil {
                    nested[test] = isDeclaredInANestedType(file.testName, suite: suite.path, in: text)
                }
                if file.testName.contains("-") || !text.contains("func \(file.testName)(") || nested[test] == true {
                    id = suite.identifier
                } else {
                    id = suite.identifier + "/" + file.testName + (isXCTest ? "" : "()")
                }
            }
            if listed.insert(id).inserted { only.append(id) }
        }
        // A suite-level identifier already covers that suite's single tests.
        let suiteIDs = Set(only.filter { suites[$0] != nil })
        only = only.filter { id in suiteIDs.contains(id) || !suiteIDs.contains(where: { id.hasPrefix($0 + "/") }) }
        return RecordSelection(suites: order.compactMap { suites[$0] }, onlyTesting: only)
    }

    /// The name swift-snapshot-testing gives a test's snapshots: its identifier with every run of
    /// other characters than letters, digits and `_` turned into `-` (`sized(width:)` → `sized-width`).
    static func snapshotName(ofTest identifier: String) -> String {
        identifier.replacingOccurrences(of: #"\W+"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Whether the suite's body declares `func <test>(` only inside braces of its own (a nested
    /// suite), not directly. Comments and strings don't count; a test declared outside the body
    /// (in an extension) isn't nested.
    static func isDeclaredInANestedType(_ test: String, suite: [String], in source: String) -> Bool {
        guard let decl = RecordPatcher.findDeclaration(of: suite, in: source),
              let close = RecordPatcher.matchingBrace(in: source, open: decl.bodyOpen) else { return false }
        let declaration = "func \(test)("
        var depth = 0, inside = false
        var i = source.index(after: decl.bodyOpen)
        while i < close {
            if let next = RecordPatcher.endOfCommentOrString(in: source, at: i) {
                i = next
                continue
            }
            switch source[i] {
            case "{": depth += 1
            case "}": depth -= 1
            case "f" where source[i...].hasPrefix(declaration):
                if depth == 0 { return false }
                inside = true
            default: break
            }
            i = source.index(after: i)
        }
        return inside
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
        pattern: #"^([ \t]*)(?:@[\w.]+(?:\([^\n]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final|open|package|nonisolated)\s+)*(?:struct|class|actor|enum)\s+(`[^`]+`|\w+)"#
    )
    private static let extensionDecl = try! NSRegularExpression(pattern: #"^extension\s+(`[^`]+`|\w+)"#)

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
