import Foundation

public enum RecordPatchError: Error, LocalizedError, Equatable {
    case declarationNotFound(suite: String, file: String)
    case xctestAlreadyOverridesInvokeTest(suite: String, file: String)
    case suiteFileNotFound(String)
    case noTopLevelTests(file: String)
    case uncommittedChanges([String])
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
        case let .uncommittedChanges(files):
            "Refusing to re-record: these files have uncommitted changes. Commit or stash them first:\n" + files.map { "  \($0)" }.joined(separator: "\n")
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
        guard let decl = findDeclaration(of: suite, in: source) else {
            throw RecordPatchError.declarationNotFound(suite: name, file: file)
        }
        if decl.isXCTest {
            return try patchXCTest(source: source, decl: decl, suite: name, file: file)
        }
        return patchSwiftTesting(source: source, decl: decl)
    }

    struct Declaration {
        /// Offset of the first modifier/keyword of the declaration line (after indentation).
        var lineStart: String.Index
        var keywordStart: String.Index
        var bodyOpen: String.Index
        var indent: String
        var isXCTest: Bool
    }

    /// The declaration of the type at `path`: its first name declared at the top of the file, each
    /// next one directly in the body of the one before, or in an `extension` of the types before it
    /// (`extension DarkTests { struct Large {} }`, `extension DarkTests.Large`). Never a type of
    /// that name nested elsewhere: two suites can each have a `Large`.
    static func findDeclaration(of path: [String], in source: String) -> Declaration? {
        if let found = findDeclaration(of: path[...], in: source, scope: source.startIndex..<source.endIndex) { return found }
        for (extended, body) in extensions(in: source) where extended.count < path.count && path.starts(with: extended) {
            if let found = findDeclaration(of: path.dropFirst(extended.count), in: source, scope: body) { return found }
        }
        return nil
    }

    private static func findDeclaration(of path: ArraySlice<String>, in source: String, scope: Range<String.Index>) -> Declaration? {
        guard let name = path.first else { return nil }
        for decl in declarations(named: name, in: source, scope: scope) {
            if path.count == 1 { return decl }
            if let close = matchingBrace(in: source, open: decl.bodyOpen),
               let found = findDeclaration(of: path.dropFirst(), in: source, scope: source.index(after: decl.bodyOpen)..<close) {
                return found
            }
        }
        return nil
    }

    /// The types named `name` declared directly in `scope`, in order.
    private static func declarations(named name: String, in source: String, scope: Range<String.Index>) -> [Declaration] {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        // Attributes may contain parentheses nested two levels deep: @Suite(.snapshots(record: .x)).
        let parens = #"\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)"#
        // The name ends where a space, the inheritance clause, generics or the body starts: there is
        // no word boundary after a raw identifier's closing backtick.
        let pattern = #"(?m)^([ \t]*)((?:@[\w.]+(?:"# + parens + #")?\s+|(?:public|internal|private|fileprivate|package|final|open|nonisolated)\s+)*)(struct|class|actor|enum)\s+"#
            + escaped + #"(?=[\s:<{])([^{]*)\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(scope, in: source)).compactMap { m in
            let lineStart = Range(m.range(at: 2), in: source)!.lowerBound
            guard isDirectly(in: scope, lineStart, of: source) else { return nil }
            let keyword = ns.substring(with: m.range(at: 3))
            let inheritance = ns.substring(with: m.range(at: 4))
            let isXCTest = keyword == "class" && inheritance.contains(":") && imports("XCTest", in: source)
                && (!imports("Testing", in: source) || inheritance.contains("XCTestCase"))
            return Declaration(lineStart: lineStart, keywordStart: Range(m.range(at: 3), in: source)!.lowerBound,
                               bodyOpen: source.index(before: Range(m.range, in: source)!.upperBound),
                               indent: ns.substring(with: m.range(at: 1)), isXCTest: isXCTest)
        }
    }

    private static let extensionDeclaration = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*((?:@[\w.]+\s+|(?:public|internal|private|fileprivate|package|nonisolated)\s+)*)extension\s+((?:`[^`]+`|\w+)(?:\s*\.\s*(?:`[^`]+`|\w+))*)[^{]*\{"#
    )

    /// The file's extensions: the path of the type each one extends, and the inside of its body.
    private static func extensions(in source: String) -> [(type: [String], body: Range<String.Index>)] {
        let file = source.startIndex..<source.endIndex
        let ns = source as NSString
        return extensionDeclaration.matches(in: source, range: NSRange(file, in: source)).compactMap { m in
            let open = source.index(before: Range(m.range, in: source)!.upperBound)
            guard isDirectly(in: file, Range(m.range(at: 1), in: source)!.lowerBound, of: source),
                  let close = matchingBrace(in: source, open: open) else { return nil }
            let type = ns.substring(with: m.range(at: 2)).matches(of: /`[^`]+`|\w+/).map { String($0.output) }
            return (type, source.index(after: open)..<close)
        }
    }

    /// Whether `index` is directly in `scope`: not in braces opened in it, nor in a comment or string.
    private static func isDirectly(in scope: Range<String.Index>, _ index: String.Index, of source: String) -> Bool {
        var depth = 0
        var i = scope.lowerBound
        while i < index {
            if let next = endOfCommentOrString(in: source, at: i) {
                if next > index { return false }
                i = next
                continue
            }
            switch source[i] {
            case "{": depth += 1
            case "}": depth -= 1
            default: break
            }
            i = source.index(after: i)
        }
        return depth == 0
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
        let attributeRegion = source[searchStart..<decl.keywordStart]

        if let suiteRange = attributeRegion.range(of: #"@Suite\b"#, options: [.regularExpression, .backwards]) {
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
