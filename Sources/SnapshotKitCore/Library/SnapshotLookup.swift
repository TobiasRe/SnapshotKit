import Foundation

/// The snapshots of a test, or of a test file, named in selected text: what Open in SnapshotKit shows,
/// the Services menu item (in Xcode, also in the editor's context menu under Services).
public enum SnapshotLookup {
    /// The name `selection` gives, as snapshot names spell it: a test function's (`payButton`,
    /// `@Test func payButton()`, `` `pay button` ``) or a type's (`CardTests`, `struct CardTests {`).
    /// Nil when it has none.
    public static func name(in selection: String) -> String? {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: 0, length: (text as NSString).length)
        for pattern in [function, type, identifier] {
            guard let match = pattern.firstMatch(in: text, range: range) else { continue }
            let name = TestSourceLocator.sanitized((text as NSString).substring(with: match.range(at: 1)))
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// The snapshots of the test functions called `name` (a parameterized `sizes(width:)` too), or,
    /// when there are none, of the test file called `name`.
    public static func snapshots(named name: String, in files: [SnapshotFile]) -> [SnapshotFile] {
        let tests = files.filter { TestSourceLocator.isFunction(name, ofTest: $0.testName) }
        return tests.isEmpty ? files.filter { $0.suite == name } : tests
    }

    private static let function = try! NSRegularExpression(pattern: #"\b"# + TestSourceLocator.functionDeclaration)
    private static let type = try! NSRegularExpression(pattern: #"\b(?:struct|class|enum|actor|extension)\s+(`[^`]+`|\w+)"#)
    private static let identifier = try! NSRegularExpression(pattern: #"(`[^`]+`|[A-Za-z_]\w*)"#)
}
