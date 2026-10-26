import Foundation

public enum RecordPatchError: Error, LocalizedError, Equatable {
    case declarationNotFound(suite: String, file: String)
    case xctestAlreadyOverridesInvokeTest(suite: String, file: String)
    case suiteFileNotFound(String)
    case noTopLevelTests(file: String)
    case patchAlreadyActive(String)

    public var errorDescription: String? {
        switch self {
        case let .declarationNotFound(suite, file):
            "Could not find the declaration of suite “\(suite)” in \(file)."
        case let .xctestAlreadyOverridesInvokeTest(suite, file):
            "“\(suite)” in \(file) already overrides invokeTest(); re-record it manually."
        case let .suiteFileNotFound(suite):
            "Could not find the source file for suite “\(suite)”."
        case let .noTopLevelTests(file):
            "Could not find a @Test function outside a type in \(file)."
        case let .patchAlreadyActive(repo):
            "A re-record is already in progress for \(repo)."
        }
    }
}

/// Rewrites a test suite's source so its snapshots are recorded instead of asserted.
///
/// - Swift Testing: sets `.snapshots(record: .all)` on the suite's `@Suite` attribute
///   (adding the attribute or trait when missing, replacing an existing `record:` value), or for
///   the tests outside any type on each one's `@Test` attribute.
/// - XCTest: adds an `invokeTest()` override that wraps the test in
///   `withSnapshotTesting(record: .all)`.
public enum RecordPatcher {
    public static let marker = "snapshotkit:record"

    /// `source` with record mode on for the suite type at `suite`, its path in the test bundle
    /// (`["DarkTests", "Large"]` for a `Large` nested in `DarkTests`), or, for nil, for the tests
    /// declared outside any type.
    public static func patch(source: String, suite: [String]?, file: String = "file") throws -> String {
        // A byte order mark would hide a first-line `import XCTest` from the patterns below.
        if source.hasPrefix("\u{FEFF}") { return "\u{FEFF}" + (try patch(source: String(source.dropFirst()), suite: suite, file: file)) }
        guard let suite else { return try patchTopLevelTests(source: source, file: file) }
        let name = suite.joined(separator: ".")
        // A type declared more than once is so in the branches of an `#if`: each one gets the patch.
        let count = findDeclarations(of: suite, in: source).count
        guard count > 0 else { throw RecordPatchError.declarationNotFound(suite: name, file: file) }
        var patched = source
        for i in 0..<count {
            // Found again in the text patched so far: the patches before moved it.
            let decl = findDeclarations(of: suite, in: patched)[i]
            patched = decl.isXCTest ? try patchXCTest(source: patched, decl: decl, suite: name, file: file)
                : patchSwiftTesting(source: patched, decl: decl)
        }
        return patched
    }

    struct Declaration {
        var name: String
        /// Offset of the first modifier/keyword of the declaration line (after indentation).
        var lineStart: String.Index
        var keywordStart: String.Index
        var bodyOpen: String.Index
        var indent: String
        /// A class's inheritance clause (` : XCTestCase `), if it is a class that has one.
        var classInheritance: String?
        /// Set by `findDeclarations`, which reads what the file imports once for all its types.
        var isXCTest = false
    }

    /// The declaration of the type at `path`: its first name declared at the top of the file, each
    /// next one directly in the body of the one before, or in an `extension` of the types before it
    /// (`extension DarkTests { struct Large {} }`, `extension DarkTests.Large`). Never a type of
    /// that name nested elsewhere: two suites can each have a `Large`.
    static func findDeclaration(of path: [String], in source: String) -> Declaration? {
        findDeclarations(of: path, in: source).first
    }

    /// Every declaration of the type at `path`, as `findDeclaration` finds one, in order.
    static func findDeclarations(of path: [String], in source: String) -> [Declaration] {
        let found = findDeclarations(of: path[...], in: source, scope: source.startIndex..<source.endIndex)
            + extensions(in: source).filter { $0.type.count < path.count && path.starts(with: $0.type) }
                .flatMap { findDeclarations(of: path.dropFirst($0.type.count), in: source, scope: $0.body) }
        guard found.contains(where: { $0.classInheritance != nil }) else { return found }
        let xctest = imports("XCTest", in: source), testing = imports("Testing", in: source)
        return found.map { decl in
            var decl = decl
            decl.isXCTest = xctest && decl.classInheritance.map { !testing || $0.contains("XCTestCase") } ?? false
            return decl
        }
    }

    private static func findDeclarations(of path: ArraySlice<String>, in source: String, scope: Range<String.Index>) -> [Declaration] {
        guard let name = path.first else { return [] }
        return declarations(named: name, in: source, scope: scope).flatMap { decl -> [Declaration] in
            if path.count == 1 { return [decl] }
            guard let close = matchingBrace(in: source, open: decl.bodyOpen) else { return [] }
            return findDeclarations(of: path.dropFirst(), in: source, scope: source.index(after: decl.bodyOpen)..<close)
        }
    }

    /// The path of every type `findDeclaration` finds, in the order they are declared: the types at
    /// the top of the file, in the body of one of them, or in an extension's
    /// (`["AllSnapshots", "Rows", "RowTests"]` in `extension AllSnapshots.Rows`).
    static func typePaths(in source: String) -> [[String]] {
        func paths(in scope: Range<String.Index>, of parent: [String]) -> [(path: [String], start: String.Index)] {
            declarations(named: nil, in: source, scope: scope).flatMap { decl in
                let path = parent + [decl.name]
                let nested = matchingBrace(in: source, open: decl.bodyOpen).map { paths(in: source.index(after: decl.bodyOpen)..<$0, of: path) }
                return [(path, decl.lineStart)] + (nested ?? [])
            }
        }
        let found = paths(in: source.startIndex..<source.endIndex, of: []) + extensions(in: source).flatMap { paths(in: $0.body, of: $0.type) }
        return found.sorted { $0.start < $1.start }.map(\.path)
    }

    /// The types named `name`, or for nil of any name, declared directly in `scope`, in order.
    private static func declarations(named name: String?, in source: String, scope: Range<String.Index>) -> [Declaration] {
        let identifier = name.map(NSRegularExpression.escapedPattern(for:)) ?? #"`[^`]+`|\w+"#
        // Attributes may contain parentheses nested two levels deep: @Suite(.snapshots(record: .x)).
        let parens = #"\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)"#
        // The name ends where a space, the inheritance clause, generics or the body starts: there is
        // no word boundary after a raw identifier's closing backtick.
        let pattern = #"(?m)^([ \t]*)((?:@[\w.]+(?:"# + parens + #")?\s+|(?:public|internal|private|fileprivate|package|final|open|nonisolated)\s+)*)(struct|class|actor|enum)\s+("#
            + identifier + #")(?=[\s:<{])([^{]*)\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        var scanner = ScopeScanner(scope, of: source)
        return regex.matches(in: source, range: NSRange(scope, in: source)).compactMap { m in
            let lineStart = Range(m.range(at: 2), in: source)!.lowerBound
            let name = ns.substring(with: m.range(at: 4))
            // `class func`, `class var`: a class member, not a type.
            guard !memberKeywords.contains(name), scanner.isDirectlyIn(lineStart) else { return nil }
            let inheritance = ns.substring(with: m.range(at: 5))
            return Declaration(name: name, lineStart: lineStart, keywordStart: Range(m.range(at: 3), in: source)!.lowerBound,
                               bodyOpen: source.index(before: Range(m.range, in: source)!.upperBound),
                               indent: ns.substring(with: m.range(at: 1)),
                               classInheritance: ns.substring(with: m.range(at: 3)) == "class" && inheritance.contains(":") ? inheritance : nil)
        }
    }

    private static let memberKeywords: Set = ["func", "var", "let", "subscript", "init", "deinit", "override", "final", "static",
                                              "required", "convenience", "dynamic", "lazy", "nonisolated", "public", "package",
                                              "internal", "fileprivate", "private", "open"]

    private static let extensionDeclaration = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*((?:@[\w.]+\s+|(?:public|internal|private|fileprivate|package|nonisolated)\s+)*)extension\s+((?:`[^`]+`|\w+)(?:\s*\.\s*(?:`[^`]+`|\w+))*)[^{]*\{"#
    )

    /// The file's extensions: the path of the type each one extends, and the inside of its body.
    private static func extensions(in source: String) -> [(type: [String], body: Range<String.Index>)] {
        let file = source.startIndex..<source.endIndex
        var scanner = ScopeScanner(file, of: source)
        let ns = source as NSString
        return extensionDeclaration.matches(in: source, range: NSRange(file, in: source)).compactMap { m in
            let open = source.index(before: Range(m.range, in: source)!.upperBound)
            guard scanner.isDirectlyIn(Range(m.range(at: 1), in: source)!.lowerBound),
                  let close = matchingBrace(in: source, open: open) else { return nil }
            let type = ns.substring(with: m.range(at: 2)).matches(of: /`[^`]+`|\w+/).map { String($0.output) }
            return (type, source.index(after: open)..<close)
        }
    }

    /// Tells whether indexes of a scope are directly in it: not in braces opened in it, nor in a
    /// comment or string. Asked in increasing order, it reads the scope once for all of them: read
    /// again from its start for each, a file of a hundred nested suites took seconds.
    private struct ScopeScanner {
        private let source: String
        private var position: String.Index
        private var depth = 0

        init(_ scope: Range<String.Index>, of source: String) {
            self.source = source
            position = scope.lowerBound
        }

        /// Whether `index`, at or after the one asked about before, is directly in the scope.
        mutating func isDirectlyIn(_ index: String.Index) -> Bool {
            while position < index {
                if let next = endOfCommentOrString(in: source, at: position) {
                    position = next     // past `index` if it is in there
                    continue
                }
                switch source[position] {
                case "{": depth += 1
                case "}": depth -= 1
                default: break
                }
                position = source.index(after: position)
            }
            return position == index && depth == 0
        }
    }

    /// Whether `source` imports `module`, however: `@testable` or `@preconcurrency`, with an access
    /// level (`internal import`), or one declaration of it (`import class XCTest.XCTestCase`).
    static func imports(_ module: String, in source: String) -> Bool {
        let pattern = #"(?m)^[ \t]*(?:@\w+\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+"#
            + #"(?:(?:class|struct|enum|protocol|typealias|func|var|let)\s+)?"# + NSRegularExpression.escapedPattern(for: module) + #"\b"#
        return source.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Swift Testing

    static func patchSwiftTesting(source: String, decl: Declaration) -> String {
        // The suite's own attributes sit between the previous `{`/`}` (or file start) and the keyword.
        let searchStart = lastScopeBrace(in: source, before: decl.lineStart).map { source.index(after: $0) } ?? source.startIndex

        if let suiteRange = lastSuiteAttribute(in: source, searchStart..<decl.keywordStart) {
            let afterSuite = suiteRange.upperBound
            if afterSuite < source.endIndex, source[afterSuite] == "(",
               let close = matchingParen(in: source, open: afterSuite) {
                let argsRange = source.index(after: afterSuite)..<close
                let newArgs = patchTraitArguments(String(source[argsRange]))
                return source.replacingCharacters(in: argsRange, with: newArgs)
            }
            return source.replacingCharacters(in: suiteRange, with: "@Suite(.snapshots(record: .all))")
        }
        var result = source
        result.insert(contentsOf: "@Suite(.snapshots(record: .all)) // \(marker)\n" + decl.indent, at: decl.lineStart)
        return result
    }

    /// The last `@Suite` in `region`, not one in a comment or string (`/// Not a @Suite(…)`).
    private static func lastSuiteAttribute(in source: String, _ region: Range<String.Index>) -> Range<String.Index>? {
        var last: Range<String.Index>?
        var i = region.lowerBound
        while i < region.upperBound {
            if let next = endOfCommentOrString(in: source, at: i) {
                i = next
                continue
            }
            if source[i...].hasPrefix("@Suite") {
                let end = source.index(i, offsetBy: 6)
                if end == source.endIndex || !(source[end].isLetter || source[end].isNumber || source[end] == "_") { last = i..<end }
                i = end
                continue
            }
            i = source.index(after: i)
        }
        return last
    }

    /// Given the text inside `@Suite( … )`, returns it with record mode forced to `.all`.
    static func patchTraitArguments(_ args: String) -> String {
        if let snap = args.range(of: ".snapshots(") {
            let open = args.index(before: snap.upperBound)
            guard let close = matchingParen(in: args, open: open) else { return args }
            let inner = args[args.index(after: open)..<close]
            if let rec = inner.range(of: #"record\s*:"#, options: .regularExpression) {
                // Replace the value up to the next top-level comma or the closing paren.
                var depth = 0
                var end = rec.upperBound
                while end < close {
                    let ch = args[end]
                    if ch == "(" || ch == "[" { depth += 1 }
                    if ch == ")" || ch == "]" { depth -= 1 }
                    if ch == "," && depth == 0 { break }
                    end = args.index(after: end)
                }
                return args.replacingCharacters(in: rec.lowerBound..<end, with: "record: .all")
            }
            let insertion = inner.trimmingCharacters(in: .whitespaces).isEmpty ? "record: .all" : "record: .all, "
            var result = args
            result.insert(contentsOf: insertion, at: args.index(after: open))
            return result
        }
        // Right after the last argument, so a trailing comment or newline (multi-line attributes)
        // stays after the new trait, and a trailing comma isn't doubled.
        let end = endOfLastArgument(in: args)
        if end == args.startIndex { return ".snapshots(record: .all)" }
        var result = args
        result.insert(contentsOf: args[..<end].hasSuffix(",") ? " .snapshots(record: .all)" : ", .snapshots(record: .all)", at: end)
        return result
    }

    /// The index after the last character of `args` that isn't whitespace or in a comment.
    private static func endOfLastArgument(in args: String) -> String.Index {
        var end = args.startIndex
        var i = args.startIndex
        while i < args.endIndex {
            if let next = endOfCommentOrString(in: args, at: i) {
                if args[i] != "/" { end = next } // a string, not a comment
                i = next
            } else {
                if !args[i].isWhitespace { end = args.index(after: i) }
                i = args.index(after: i)
            }
        }
        return end
    }

    // MARK: Swift Testing, outside a type

    /// A `@Test` function declared outside any type, as `-only-testing` names it (`sized(width:)`).
    struct TopLevelTest {
        /// `@Test` and its arguments, if any.
        var attribute: Range<String.Index>
        var identifier: String
    }

    /// The `@Test` functions of `source` declared outside any type, in order.
    static func topLevelTests(in source: String) -> [TopLevelTest] {
        var tests: [TopLevelTest] = []
        var depth = 0
        var i = source.startIndex
        while i < source.endIndex {
            if let next = endOfCommentOrString(in: source, at: i) {
                i = next
                continue
            }
            switch source[i] {
            case "{": depth += 1
            case "}": depth = max(depth - 1, 0)
            case "@" where depth == 0 && source[i...].hasPrefix("@Test"):
                var end = source.index(i, offsetBy: 5)
                guard end == source.endIndex || !(source[end].isLetter || source[end].isNumber || source[end] == "_") else { break }
                if end < source.endIndex, source[end] == "(", let close = matchingParen(in: source, open: end) { end = source.index(after: close) }
                if let identifier = identifierOfFunction(in: source, after: end) { tests.append(TopLevelTest(attribute: i..<end, identifier: identifier)) }
                i = end
                continue
            default: break
            }
            i = source.index(after: i)
        }
        return tests
    }

    /// The other attributes and modifiers a test function can have between `@Test` and `func`.
    private static let functionAfterAttribute = try! NSRegularExpression(
        pattern: #"^(?:\s+|@[\w.]+(?:\([^()]*\))?|(?:public|internal|private|fileprivate|package|nonisolated)\b)*"#
            + TestSourceLocator.functionDeclaration
    )

    /// `name(label:…)` for the function declared after `index`, if one is.
    private static func identifierOfFunction(in source: String, after index: String.Index) -> String? {
        let ns = source as NSString
        let start = NSRange(index..<source.endIndex, in: source)
        guard let m = functionAfterAttribute.firstMatch(in: source, options: .anchored, range: start),
              let open = Range(m.range, in: source).map({ source.index(before: $0.upperBound) }),
              let close = matchingParen(in: source, open: open) else { return nil }
        // Each parameter's first word is its label: `_ x: Int` is `_:`, `width: Int` is `width:`.
        let labels = splitTopLevel(String(source[source.index(after: open)..<close])).compactMap { parameter in
            parameter.split(whereSeparator: { $0.isWhitespace || $0 == ":" }).first.map { $0 + ":" }
        }
        return ns.substring(with: m.range(at: 1)) + "(" + labels.joined() + ")"
    }

    /// `text` split at its commas outside brackets, comments and strings.
    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = [], current = ""
        var depth = 0
        var i = text.startIndex
        while i < text.endIndex {
            if let next = endOfCommentOrString(in: text, at: i) {
                current += text[i..<next]
                i = next
                continue
            }
            switch text[i] {
            case "(", "[", "<": depth += 1
            case "-" where text[i...].hasPrefix("->"):        // a function type's arrow, not a bracket
                current += "->"
                i = text.index(i, offsetBy: 2)
                continue
            case ")", "]", ">": depth -= 1
            case "," where depth == 0:
                parts.append(current)
                current = ""
                i = text.index(after: i)
                continue
            default: break
            }
            current.append(text[i])
            i = text.index(after: i)
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(current) }
        return parts
    }

    /// Sets `.snapshots(record: .all)` on every `@Test` function outside a type: swift-snapshot-testing
    /// takes the trait on a test as well as on a suite.
    static func patchTopLevelTests(source: String, file: String) throws -> String {
        let tests = topLevelTests(in: source)
        guard !tests.isEmpty else { throw RecordPatchError.noTopLevelTests(file: file) }
        var result = source
        for test in tests.reversed() {
            let attribute = String(source[test.attribute])
            let patched = attribute == "@Test" ? "@Test(.snapshots(record: .all))"
                : "@Test(" + patchTestArguments(String(attribute.dropFirst(6).dropLast())) + ")"
            result.replaceSubrange(test.attribute, with: patched)
        }
        return result
    }

    /// Given the text inside `@Test( … )`, returns it with record mode forced to `.all`. A new trait
    /// goes before `arguments:`, which comes last.
    static func patchTestArguments(_ args: String) -> String {
        guard !args.contains(".snapshots("),
              let arguments = splitTopLevel(args).firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("arguments:") })
        else { return patchTraitArguments(args) }
        var parts = splitTopLevel(args)
        let indent = String(parts[arguments].prefix { $0.isWhitespace })
        parts.insert(indent + ".snapshots(record: .all)", at: arguments)
        if arguments == 0 { parts[1] = " " + parts[1].drop { $0.isWhitespace } }
        return parts.joined(separator: ",")
    }

    // MARK: XCTest

    static func patchXCTest(source: String, decl: Declaration, suite: String, file: String) throws -> String {
        guard let close = matchingBrace(in: source, open: decl.bodyOpen) else {
            throw RecordPatchError.declarationNotFound(suite: suite, file: file)
        }
        if source[decl.bodyOpen..<close].contains("func invokeTest()") {
            throw RecordPatchError.xctestAlreadyOverridesInvokeTest(suite: suite, file: file)
        }
        let line = "\n\(decl.indent)    override func invokeTest() { withSnapshotTesting(record: .all) { super.invokeTest() } } // \(marker)"
        var result = source
        result.insert(contentsOf: line, at: source.index(after: decl.bodyOpen))
        return result
    }

    // MARK: Scanning helpers

    /// The last `{` or `}` before `end` that opens or closes a scope: not one in a comment or string
    /// (a doc comment's example), nor in parentheses (a closure in an attribute's arguments).
    static func lastScopeBrace(in text: String, before end: String.Index) -> String.Index? {
        var last: String.Index?
        var depth = 0
        var i = text.startIndex
        while i < end {
            if let next = endOfCommentOrString(in: text, at: i) {
                i = next
                continue
            }
            switch text[i] {
            case "(": depth += 1
            case ")": depth = max(depth - 1, 0)
            case "{", "}": if depth == 0 { last = i }
            default: break
            }
            i = text.index(after: i)
        }
        return last
    }

    /// Index of the `)` matching the `(` at `open`, skipping comments and string literals.
    static func matchingParen(in text: String, open: String.Index) -> String.Index? {
        matching(in: text, open: open, openChar: "(", closeChar: ")")
    }

    static func matchingBrace(in text: String, open: String.Index) -> String.Index? {
        matching(in: text, open: open, openChar: "{", closeChar: "}")
    }

    private static func matching(in text: String, open: String.Index, openChar: Character, closeChar: Character) -> String.Index? {
        var depth = 0
        var i = open
        while i < text.endIndex {
            if let end = endOfCommentOrString(in: text, at: i) {
                i = end
                continue
            }
            if text[i] == openChar {
                depth += 1
            } else if text[i] == closeChar {
                depth -= 1
                if depth == 0 { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Where the comment or string literal starting at `i` ends, or nil if none starts there.
    /// Handles `//` and (nested) `/* */` comments, escapes, multi-line `"""` and raw `#"…"#`
    /// strings; an interpolation's own strings are not told apart.
    static func endOfCommentOrString(in text: String, at i: String.Index) -> String.Index? {
        // Asked at every character a scan passes: most of them can't start either.
        switch text[i] {
        case "/", "\"", "#": break
        default: return nil
        }
        let rest = text[i...]
        if rest.hasPrefix("//") { return rest.firstIndex(where: \.isNewline) ?? text.endIndex } // "\r\n" is one Character
        if rest.hasPrefix("/*") {
            var depth = 0
            var j = i
            while j < text.endIndex {
                if text[j...].hasPrefix("/*") {
                    depth += 1
                    j = text.index(j, offsetBy: 2)
                } else if text[j...].hasPrefix("*/") {
                    depth -= 1
                    j = text.index(j, offsetBy: 2)
                    if depth == 0 { return j }
                } else {
                    j = text.index(after: j)
                }
            }
            return text.endIndex
        }
        let hashes = String(rest.prefix { $0 == "#" })
        let quoteStart = text.index(i, offsetBy: hashes.count)
        guard text[quoteStart...].hasPrefix("\"") else { return nil }
        let quotes = text[quoteStart...].hasPrefix("\"\"\"") ? "\"\"\"" : "\""
        // In a raw string only `\#` escapes, and only `"#` closes it.
        let close = quotes + hashes, escape = "\\" + hashes
        var j = text.index(quoteStart, offsetBy: quotes.count)
        while j < text.endIndex {
            if text[j...].hasPrefix(escape) {
                j = text.index(j, offsetBy: escape.count)
                if j < text.endIndex { j = text.index(after: j) }
            } else if text[j...].hasPrefix(close) {
                return text.index(j, offsetBy: close.count)
            } else {
                j = text.index(after: j)
            }
        }
        return text.endIndex
    }
}
