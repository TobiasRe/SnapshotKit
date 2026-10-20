import Foundation

public enum RecordPatchError: Error, LocalizedError, Equatable {
    case declarationNotFound(suite: String, file: String)
    case xctestAlreadyOverridesInvokeTest(suite: String, file: String)
    case suiteFileNotFound(String)
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
///   (adding the attribute or trait when missing, replacing an existing `record:` value).
/// - XCTest: adds an `invokeTest()` override that wraps the test in
///   `withSnapshotTesting(record: .all)`.
public enum RecordPatcher {
    public static let marker = "snapshotkit:record"

    public static func patch(source: String, suite: String, file: String = "file") throws -> String {
        // A byte order mark would hide a first-line `import XCTest` from the patterns below.
        if source.hasPrefix("\u{FEFF}") { return "\u{FEFF}" + (try patch(source: String(source.dropFirst()), suite: suite, file: file)) }
        guard let decl = findDeclaration(of: suite, in: source) else {
            throw RecordPatchError.declarationNotFound(suite: suite, file: file)
        }
        if decl.isXCTest {
            return try patchXCTest(source: source, decl: decl, suite: suite, file: file)
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

    static func findDeclaration(of name: String, in source: String) -> Declaration? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        // Attributes may contain parentheses nested two levels deep: @Suite(.snapshots(record: .x)).
        let parens = #"\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)"#
        let pattern = #"(?m)^([ \t]*)((?:@[\w.]+(?:"# + parens + #")?\s+|(?:public|internal|private|fileprivate|package|final|open|nonisolated)\s+)*)(struct|class|actor|enum)\s+"# + escaped + #"\b([^{]*)\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = source as NSString
        guard let m = regex.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let indent = ns.substring(with: m.range(at: 1))
        let keyword = ns.substring(with: m.range(at: 3))
        let inheritance = ns.substring(with: m.range(at: 4))
        let lineStart = Range(m.range(at: 2), in: source)!.lowerBound
        let keywordStart = Range(m.range(at: 3), in: source)!.lowerBound
        let bodyOpen = source.index(before: Range(m.range, in: source)!.upperBound)
        let isXCTest = keyword == "class" && inheritance.contains(":") && imports("XCTest", in: source)
            && (!imports("Testing", in: source) || inheritance.contains("XCTestCase"))
        return Declaration(lineStart: lineStart, keywordStart: keywordStart, bodyOpen: bodyOpen, indent: indent, isXCTest: isXCTest)
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
