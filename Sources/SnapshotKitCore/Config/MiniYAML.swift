import Foundation

/// A deliberately small YAML subset reader for `.snapshotkit.yml`:
/// top-level `key: value` scalars, inline lists (`[a, b]`) and block lists (`- a`).
enum MiniYAML {
    enum Value: Equatable, Sendable {
        case scalar(String)
        case list([String])

        var string: String? {
            if case .scalar(let s) = self { return s }
            return nil
        }

        var strings: [String] {
            switch self {
            case .scalar(let s): s.isEmpty ? [] : [s]
            case .list(let l): l
            }
        }
    }

    struct ParseError: Error, LocalizedError {
        var line: Int
        var message: String
        var errorDescription: String? { "line \(line): \(message)" }
    }

    static func parse(_ text: String) throws -> [String: Value] {
        var result: [String: Value] = [:]
        var currentListKey: String?
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = stripComment(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let indented = line.first == " " || line.first == "\t"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The start and end of the document, not settings.
            if !indented, trimmed == "---" || trimmed == "..." { continue }

            if trimmed.hasPrefix("- ") || trimmed == "-" {
                guard let key = currentListKey else {
                    throw ParseError(line: offset + 1, message: "list item without a key")
                }
                let item = unquote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                if case .list(var items) = result[key] ?? .list([]) {
                    items.append(item)
                    result[key] = .list(items)
                }
                continue
            }
            if indented {
                throw ParseError(line: offset + 1, message: "nested mappings are not supported")
            }
            guard let colon = trimmed.firstIndex(of: ":") else {
                throw ParseError(line: offset + 1, message: "expected `key: value`")
            }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                result[key] = .list([])
                currentListKey = key
            } else if rest.hasPrefix("["), rest.hasSuffix("]") {
                result[key] = .list(splitInlineList(String(rest.dropFirst().dropLast())))
                currentListKey = nil
            } else {
                result[key] = .scalar(unquote(rest))
                currentListKey = nil
            }
        }
        return result
    }

    static func splitInlineList(_ body: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quoting = Quoting()
        for ch in body {
            if !quoting.isQuoted(ch), ch == "," {
                items.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        items.append(current)
        return items.map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    /// The value of a scalar: a quoted one without its quotes and with its escapes decoded (`\"`
    /// and `\\` in double quotes, `''` in single quotes), any other as it is written.
    static func unquote(_ s: String) -> String {
        guard let quote = s.first, quote == "\"" || quote == "'" else { return s }
        var value = ""
        var rest = s.dropFirst()
        while let ch = rest.popFirst() {
            if ch == quote {
                if quote == "'", rest.first == "'" {
                    value.append(rest.removeFirst())
                    continue
                }
                // Closed before the end: not one quoted scalar.
                return rest.isEmpty ? value : s
            }
            if quote == "\"", ch == "\\" {
                guard let escaped = rest.popFirst(), let decoded = decode(escape: escaped, in: &rest) else { return s }
                value += decoded
                continue
            }
            value.append(ch)
        }
        return s    // never closed
    }

    /// The text of the escape sequence `\` `escaped` in a double-quoted scalar, taking a code
    /// point's digits (`\u00E9`) from `rest`; nil for an invalid one.
    private static func decode(escape escaped: Character, in rest: inout Substring) -> String? {
        guard let digits = ["x": 2, "u": 4, "U": 8][escaped] else { return escapes[escaped].map(String.init) }
        let hex = rest.prefix(digits)
        guard hex.count == digits, let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
        rest.removeFirst(digits)
        return String(scalar)
    }

    private static let escapes: [Character: Character] = [
        "0": "\0", "a": "\u{07}", "b": "\u{08}", "t": "\t", "\t": "\t", "n": "\n", "v": "\u{0B}", "f": "\u{0C}", "r": "\r",
        "e": "\u{1B}", " ": " ", "\"": "\"", "/": "/", "\\": "\\", "N": "\u{85}", "_": "\u{A0}", "L": "\u{2028}", "P": "\u{2029}",
    ]

    /// Removes a `#` comment that is not inside quotes.
    static func stripComment(_ line: String) -> String {
        var quoting = Quoting()
        var previous: Character = " "
        for (i, ch) in zip(line.indices, line) {
            if !quoting.isQuoted(ch), ch == "#", previous == " " || previous == "\t" || i == line.startIndex {
                return String(line[..<i])
            }
            previous = ch
        }
        return line
    }

    /// Whether a line read character by character is in quotes: a `\"` doesn't end double quotes.
    private struct Quoting {
        private var quote: Character?
        private var escaping = false

        /// Takes the next character: whether it is quoted, or one of the quotes.
        mutating func isQuoted(_ ch: Character) -> Bool {
            guard let quote else {
                if ch == "'" || ch == "\"" { self.quote = ch }
                return self.quote != nil
            }
            if escaping {
                escaping = false
            } else if quote == "\"", ch == "\\" {
                escaping = true
            } else if ch == quote {
                self.quote = nil
            }
            return true
        }
    }
}
