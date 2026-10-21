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
        var line = i
        while let parent = parent(of: line) {
            result.append(parent)
            line = parent
        }
        return result
    }

    /// The line whose block holds line `i`: the nearest before it indented less, or for a list item,
    /// the `key:` it is level with.
    private func parent(of i: Int) -> Int? {
        guard indent(i) > 0 || isListItem(i) else { return nil }
        var j = i - 1
        while j >= 0 {
            if !isBlank(j) {
                if indent(j) < indent(i) { return j }
                if indent(j) == indent(i), isListItem(i), opensCompactList(j) { return j }
            }
            j -= 1
        }
        return nil
    }

    /// Whether line `i` is a `key:` whose list items are level with it, as GitLab's documentation
    /// writes them (`script:`, then `- cd ios` at its indentation).
    private func opensCompactList(_ i: Int) -> Bool {
        guard !isListItem(i), key(i) != nil, value(i)?.isEmpty == true,
              let next = lines.indices.dropFirst(i + 1).first(where: { !isBlank($0) }) else { return false }
        return indent(next) == indent(i) && isListItem(next)
    }

    /// The lines of the block that line `parent` opens (-1: the whole document): those after it
    /// that are indented further, and the list items level with a `key:` that opens a list.
    func block(of parent: Int) -> Range<Int> {
        guard parent >= 0 else { return 0..<lines.count }
        let compact = opensCompactList(parent)
        var end = parent + 1
        while end < lines.count, isBlank(end) || indent(end) > indent(parent) || compact && indent(end) == indent(parent) && isListItem(end) {
            end += 1
        }
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

    /// The scalars line `i` holds after its key: its value, the items of an inline list (`[a, b]`),
    /// or those of the block list under it.
    func values(_ i: Int) -> [String] {
        guard let value = value(i) else { return [] }
        if value.isEmpty { return children(of: i).filter(isListItem).map { MiniYAML.unquote(content($0)) } }
        if value.hasPrefix("["), value.hasSuffix("]") { return MiniYAML.splitInlineList(String(value.dropFirst().dropLast())) }
        return [value]
    }

    // MARK: - Anchors

    /// The line of `key` in the mapping under `parent` (-1: the top level): its own, else that of a
    /// mapping merged into it (`<<: *ios`; of `<<: [*a, *b]`, the first that has it, as YAML merges).
    func line(of key: String, under parent: Int) -> Int? {
        var merged: Set<Int> = []       // an anchor merged into itself ends
        func find(under mapping: Int) -> Int? {
            let children = children(of: mapping)
            if let own = children.first(where: { self.key($0) == key }) { return own }
            for anchor in children.flatMap(mergedAnchors(at:)) where merged.insert(anchor).inserted {
                if let found = find(under: anchor) { return found }
            }
            return nil
        }
        return find(under: parent)
    }

    /// The anchored lines (`.ios: &ios`) that line `i` merges if it is `<<: *ios` or `<<: [*a, *b]`.
    private func mergedAnchors(at i: Int) -> [Int] {
        let text = content(i)
        guard text.hasPrefix("<<:") else { return [] }
        var aliases = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
        if aliases.hasPrefix("["), aliases.hasSuffix("]") { aliases = String(aliases.dropFirst().dropLast()) }
        return MiniYAML.splitInlineList(aliases).compactMap { alias in
            // An alias refers to the latest anchor of its name before it.
            alias.hasPrefix("*") ? (0..<i).last { value($0) == "&" + alias.dropFirst() } : nil
        }
    }
}
