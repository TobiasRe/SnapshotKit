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
        var functions: [String: SuiteFunctions] = [:]    // as `parsed`, found once for all of a file's tests
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
                let declared = functions[key] ?? SuiteFunctions(of: suite.path, in: text)
                functions[key] = declared
                if file.testName.contains("-") || !declared.anywhere.contains(file.testName) || declared.isDeclaredInANestedType(file.testName) {
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

    /// The functions (`func name(`) of a test file and of its suite, each found in one pass over the
    /// file and one over the suite's body: a big file's hundreds of tests, each looked for with a
    /// pass of its own, took seconds.
    struct SuiteFunctions {
        /// The names after a `func ` anywhere in the file, as far as their `(`.
        private(set) var anywhere: Set<String> = []
        /// Those declared directly in the suite's body, and those in braces of its own (a nested
        /// suite's). Comments and strings don't count, nor functions outside the body (in an extension).
        private var direct: Set<String> = [], nested: Set<String> = []

        init(of suite: [String], in source: String) {
            for match in source.ranges(of: "func ") {
                if let name = Self.name(at: match.lowerBound, in: source) { anywhere.insert(name) }
            }
            guard let decl = RecordPatcher.findDeclaration(of: suite, in: source),
                  let close = RecordPatcher.matchingBrace(in: source, open: decl.bodyOpen) else { return }
            var depth = 0
            var i = source.index(after: decl.bodyOpen)
            while i < close {
                if let next = RecordPatcher.endOfCommentOrString(in: source, at: i) {
                    i = next
                    continue
                }
                switch source[i] {
                case "{": depth += 1
                case "}": depth -= 1
                case "f":
                    if let name = Self.name(at: i, in: source) {
                        if depth == 0 { direct.insert(name) } else { nested.insert(name) }
                    }
                default: break
                }
                i = source.index(after: i)
            }
        }

        /// Whether the suite's body declares `func <test>(` only inside braces of its own (a nested
        /// suite), not directly.
        func isDeclaredInANestedType(_ test: String) -> Bool {
            !direct.contains(test) && nested.contains(test)
        }

        /// The name of the function declared at `i`, if `func ` starts there: up to its `(`.
        private static func name(at i: String.Index, in source: String) -> String? {
            guard source[i...].hasPrefix("func ") else { return nil }
            let start = source.index(i, offsetBy: 5)
            return source[start...].firstIndex(of: "(").map { String(source[start..<$0]) }
        }
    }

    /// The suite's path for `-only-testing`, through the types and extensions it is nested in
    /// (`["AllSnapshots", "CardTests"]`): the type named like the file if there is one (the outermost
    /// of them), else the first test type in it, else the first type.
    static func suitePath(in source: String, preferring name: String) -> [String]? {
        let declared = RecordPatcher.typePaths(in: source)
        func isTestType(_ path: [String]) -> Bool { path.last.map { $0.hasSuffix("Tests") || $0.hasSuffix("Test") } ?? false }
        return declared.filter { $0.last == name }.min { $0.count < $1.count }
            ?? declared.first(where: isTestType)
            ?? declared.first
    }
}
