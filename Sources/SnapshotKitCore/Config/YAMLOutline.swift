import Foundation

/// How a YAML document's lines nest, by their indentation: enough to find the keys around a line
/// of a CI file without parsing it (CI files use far more of YAML than `MiniYAML` reads).
struct YAMLOutline {
    /// The document's lines, without comments.
    let lines: [String]

    init(_ text: String) {
        lines = text.components(separatedBy: .newlines).map(MiniYAML.stripComment)
    }

    private func indent(_ i: Int) -> Int { lines[i].prefix { $0 == " " }.count }
    private func isBlank(_ i: Int) -> Bool { lines[i].allSatisfy(\.isWhitespace) }

    func isListItem(_ i: Int) -> Bool { lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("- ") }

    /// Line `i` without its indentation and list marker: `run: x` for `- run: x`.
    func content(_ i: Int) -> String {
        let text = lines[i].trimmingCharacters(in: .whitespaces)
        return isListItem(i) ? String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces) : text
    }

    /// The key line `i` sets, if it is `key: value` or `key:`.
    func key(_ i: Int) -> String? {
        let text = content(i)
        guard let colon = text.firstIndex(of: ":"), text[text.index(after: colon)...].first?.isWhitespace ?? true else { return nil }
        let key = text[..<colon]
        return !key.isEmpty && key.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) ? String(key) : nil
    }

    /// The value on line `i` after its key, unquoted.
    func value(_ i: Int) -> String? {
        let text = content(i)
        guard key(i) != nil, let colon = text.firstIndex(of: ":") else { return nil }
        return MiniYAML.unquote(text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// The lines whose blocks hold line `i`, innermost first.
    func ancestors(of i: Int) -> [Int] {
        var result: [Int] = []
        var threshold = indent(i)
        var j = i - 1
        while j >= 0, threshold > 0 {
            if !isBlank(j), indent(j) < threshold {
                result.append(j)
                threshold = indent(j)
            }
            j -= 1
        }
        return result
    }

    /// The lines of the block that line `parent` opens (-1: the whole document): those after it
    /// that are indented further.
    func block(of parent: Int) -> Range<Int> {
        guard parent >= 0 else { return 0..<lines.count }
        var end = parent + 1
        while end < lines.count, isBlank(end) || indent(end) > indent(parent) { end += 1 }
        return (parent + 1)..<end
    }

    /// The lines directly in the block of `parent` (-1: the top level). A list item's own line comes
    /// first: `- name: x` starts the mapping it holds.
    func children(of parent: Int) -> [Int] {
        let lines = block(of: parent).filter { !isBlank($0) }
        let first = lines.first.map(indent)
        return (parent >= 0 && isListItem(parent) ? [parent] : []) + lines.filter { indent($0) == first }
    }

    /// The value at `path` (`["defaults", "run", "working-directory"]`) in the mapping under `parent`.
    func value(at path: [String], under parent: Int) -> String? {
        guard let name = path.first, let child = children(of: parent).first(where: { key($0) == name }) else { return nil }
        return path.count == 1 ? value(child) : value(at: Array(path.dropFirst()), under: child)
    }
}
