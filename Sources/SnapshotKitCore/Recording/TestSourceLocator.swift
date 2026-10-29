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
        let sources = TestSources(repository: repository)
        guard let path = try? sources.testFile(for: file) else { return nil }
        return TestSourceLocation(path: path, line: line(ofTest: file.testName, in: sources.text(of: path) ?? ""))
    }

    /// The line of the function a snapshot's test name comes from. swift-snapshot-testing names
    /// snapshots after `#function` with every run of non-word characters made a "-": `payButton`,
    /// a parameterized `sized(width:)` gives "sized-width", a raw identifier `` `pay button` `` "pay-button".
    static func line(ofTest name: String, in source: String) -> Int? {
        functions(in: source).first { isFunction($0.name, ofTest: name) }?.line
    }

    /// Every function declared in `source`, its name as it appears in snapshot names.
    static func functions(in source: String) -> [(name: String, line: Int)] {
        source.components(separatedBy: "\n").enumerated().flatMap { index, line in
            let ns = line as NSString
            return functionName.matches(in: line, range: NSRange(location: 0, length: ns.length)).map {
                (sanitized(ns.substring(with: $0.range(at: 1))), index + 1)
            }
        }
    }

    static func isFunction(_ function: String, ofTest name: String) -> Bool {
        name == function || name.hasPrefix(function + "-")
    }

    /// `func name(`, `` func `raw name`( `` or `func name<T>(`, the name captured.
    static let functionDeclaration = #"func\s+(`[^`]+`|\w+)\s*(?:<[^>\n]*>)?\s*\("#

    private static let functionName = try! NSRegularExpression(pattern: #"\b"# + functionDeclaration)

    /// swift-snapshot-testing's `sanitizePathComponent`.
    static func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: #"\W+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
