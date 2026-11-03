import Foundation

/// A test as its source declares it: the type it is in and, unless it stands for the whole suite, its
/// function. Xcode's editor extension finds one at the cursor; the app finds its snapshots and failures.
public struct SourceTest: Hashable, Sendable {
    /// The innermost type around the function: `CheckoutViewTests`.
    public var suite: String
    /// The function as written, without parameters: `payButton`, `` `pay button` ``.
    public var function: String?

    public init(suite: String, function: String? = nil) {
        self.suite = suite
        self.function = function
    }

    /// "CheckoutViewTests.payButton", or the suite alone.
    public var name: String { [suite, function.map { $0.replacingOccurrences(of: "`", with: "") }].compactMap { $0 }.joined(separator: ".") }

    /// Whether `file` is one of this test's snapshots: swift-snapshot-testing names its folder after
    /// the test file, which by convention is named after the suite.
    public func recorded(_ file: SnapshotFile) -> Bool {
        file.suite == suite && function.map { TestSourceLocator.isFunction(TestSourceLocator.sanitized($0), ofTest: file.testName) } ?? true
    }

    /// Whether a run's `test` of `suite` is this one, by its identifier (`CheckoutViewTests/payButton()`,
    /// `…/sized(width:)`): its name may be a display name.
    public func ran(_ test: TestCaseResult, in suite: SuiteResult) -> Bool {
        let ran = TestSourceLocator.sanitized(String(test.identifier.split(separator: "/").last ?? ""))
        return suite.name == self.suite && function.map { TestSourceLocator.isFunction(TestSourceLocator.sanitized($0), ofTest: ran) } ?? true
    }

    /// The test around line `line` (zero-based) of a Swift file: the function the line is in (inside
    /// a closure of it, too) or declares, in the innermost type around it; just that type between its
    /// functions. Nil outside any type.
    public static func at(line: Int, in lines: [String]) -> SourceTest? {
        var scanner = Scanner()
        for (index, text) in lines.enumerated() {
            if index == line {
                // The line that declares the function counts as in it, as does the line of its brace.
                scanner.lookAhead(text)
                break
            }
            scanner.consume(text)
        }
        guard let typeIndex = scanner.scopes.lastIndex(where: { $0.kind == .type }) else { return nil }
        // The type's own function: a test's closures and local functions are part of it.
        let inside = scanner.scopes[(typeIndex + 1)...].first { $0.kind == .function }
        return SourceTest(suite: scanner.scopes[typeIndex].name, function: inside?.name ?? scanner.declaredHere)
    }

    /// Follows the braces of Swift source line by line, outside comments and string literals, keeping
    /// the types and functions they open.
    private struct Scanner {
        enum Kind { case type, function, other }
        struct Scope { var kind: Kind; var name: String; var depth: Int }
        var scopes: [Scope] = []
        /// A declaration whose brace hasn't come yet (it may be on a later line).
        private var pending: (kind: Kind, name: String)?
        /// The function the cursor's line declares, before its brace opens it.
        private(set) var declaredHere: String?
        private var depth = 0
        private var inBlockComment = false
        private var inMultilineString = false

        mutating func consume(_ line: String) {
            for token in tokens(line) {
                switch token {
                case .declaration(let kind, let name): pending = (kind, name)
                case .open:
                    depth += 1
                    let opened = pending ?? (.other, "")
                    scopes.append(Scope(kind: opened.kind, name: opened.name, depth: depth))
                    pending = nil
                case .close:
                    if scopes.last?.depth == depth { scopes.removeLast() }
                    depth = max(0, depth - 1)
                }
            }
        }

        /// What the cursor's line declares, without opening it: the function, if it is one.
        mutating func lookAhead(_ line: String) {
            if case .declaration(.function, let name)? = tokens(line).first(where: { if case .declaration = $0 { true } else { false } }) {
                declaredHere = name
            } else if let pending, pending.kind == .function {
                // The brace of a function declared on the line above.
                declaredHere = pending.name
            }
        }

        enum Token { case declaration(Kind, String), open, close }

        private mutating func tokens(_ line: String) -> [Token] {
            var code = ""
            var chars = Array(line)[...]
            while let c = chars.first {
                if inBlockComment {
                    if chars.starts(with: "*/") { inBlockComment = false; chars = chars.dropFirst(2) } else { chars = chars.dropFirst() }
                } else if inMultilineString {
                    if chars.starts(with: "\"\"\"") { inMultilineString = false; chars = chars.dropFirst(3) } else { chars = chars.dropFirst() }
                } else if chars.starts(with: "//") {
                    break
                } else if chars.starts(with: "/*") {
                    inBlockComment = true; chars = chars.dropFirst(2)
                } else if chars.starts(with: "\"\"\"") {
                    inMultilineString = true; chars = chars.dropFirst(3)
                } else if c == "\"" {
                    // To the closing quote, past escaped ones.
                    chars = chars.dropFirst()
                    while let s = chars.first, s != "\"" { chars = chars.dropFirst(s == "\\" ? 2 : 1) }
                    chars = chars.dropFirst()
                    code += "\"\""
                } else {
                    code.append(c); chars = chars.dropFirst()
                }
            }
            var result: [Token] = []
            let ns = code as NSString
            var location = 0
            for match in Self.pattern.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                result += braces(in: ns.substring(with: NSRange(location: location, length: match.range.location - location)))
                let keyword = ns.substring(with: match.range(at: 1))
                let name = ns.substring(with: match.range(at: 2))
                result.append(.declaration(keyword == "func" ? .function : .type, name))
                location = match.range.location + match.range.length
            }
            result += braces(in: ns.substring(from: location))
            return result
        }

        private func braces(in text: String) -> [Token] {
            text.compactMap { $0 == "{" ? .open : $0 == "}" ? .close : nil }
        }

        /// `struct Name`, `final class Name`, `extension Name`, `func name`, the keyword and name captured;
        /// `class func name` is a function.
        static let pattern = try! NSRegularExpression(pattern: #"\b(class|struct|enum|actor|extension|func)\s+(?!func\b|var\b|let\b)(`[^`]+`|\w+)"#)
    }
}
