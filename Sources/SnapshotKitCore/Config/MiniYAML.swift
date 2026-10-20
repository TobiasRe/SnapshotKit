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
        var quote: Character?
        for ch in body {
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
            } else if ch == "'" || ch == "\"" {
                quote = ch
                current.append(ch)
            } else if ch == "," {
                items.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        items.append(current)
        return items.map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    static func unquote(_ s: String) -> String {
        if s.count >= 2, let f = s.first, let l = s.last, f == l, f == "\"" || f == "'" {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    /// Removes a `#` comment that is not inside quotes.
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for (i, ch) in zip(line.indices, line) {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "#", previous == " " || previous == "\t" || i == line.startIndex {
                return String(line[..<i])
            }
            previous = ch
        }
        return line
    }
}
