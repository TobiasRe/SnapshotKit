import Foundation

/// Subsequence matching for the quick switcher: "skt" matches "SnapshotKit".
/// Consecutive matches and matches at word starts score higher.
public enum FuzzyMatcher {
    public static func score(_ query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let original = Array(candidate)
        let c = Array(candidate.lowercased())
        var qi = 0, score = 0, previousMatch = -2
        for (i, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            var points = 1
            if i == previousMatch + 1 { points += 5 }
            if i == 0 { points += 8 }
            else {
                let prev = original[i - 1]
                if prev == "/" || prev == "-" || prev == "_" || prev == " " || prev == "." { points += 6 }
                else if original[i].isUppercase && prev.isLowercase { points += 4 }
            }
            score += points
            previousMatch = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score - c.count / 10
    }

    /// Ranks by a primary key (e.g. the project name) and falls back to a secondary key
    /// (e.g. its path) with a large penalty, so name matches always come first.
    public static func rank<T>(_ items: [T], query: String, primary: (T) -> String, secondary: (T) -> String) -> [T] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        var scored: [(index: Int, item: T, score: Int)] = []
        for (index, item) in items.enumerated() {
            if let s = score(query, in: primary(item)) {
                scored.append((index, item, s + 1000))
            } else if let s = score(query, in: secondary(item)) {
                scored.append((index, item, s))
            }
        }
        scored.sort { a, b in a.score == b.score ? a.index < b.index : a.score > b.score }
        return scored.map(\.item)
    }

    /// Candidates that match, best first; ties keep their original order.
    public static func rank<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        var scored: [(index: Int, item: T, score: Int)] = []
        for (index, item) in items.enumerated() {
            if let s = score(query, in: key(item)) { scored.append((index, item, s)) }
        }
        scored.sort { a, b in a.score == b.score ? a.index < b.index : a.score > b.score }
        return scored.map(\.item)
    }
}
