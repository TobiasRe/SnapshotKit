import Foundation

/// Minimal POSIX-shell word splitting (quotes and backslashes), enough to read
/// command lines out of CI scripts.
public enum ShellWords {
    public static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaping = false
        for ch in line {
            if escaping {
                current.append(ch)
                escaping = false
                inWord = true
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if ch == "\\" && q == "\"" {
                    escaping = true
                } else {
                    current.append(ch)
                }
                continue
            }
            switch ch {
            case "\\":
                escaping = true
            case "'", "\"":
                quote = ch
                inWord = true
            case " ", "\t":
                if inWord { words.append(current); current = ""; inWord = false }
            default:
                current.append(ch)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// Cuts a command line at the first unquoted shell control operator
    /// (`|`, `&&`, `;`, `>` …) so piping into a formatter does not leak arguments.
    public static func firstCommand(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for (index, ch) in zip(line.indices, line) {
            if let q = quote {
                if ch == q && previous != "\\" { quote = nil }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "|" || ch == ";" || ch == ">" || ch == "<" || (ch == "&" && previous == "&") {
                var end = index
                if ch == "&" { end = line.index(before: index) }
                return String(line[..<end])
            } else if ch == "#" && (previous == " " || previous == "\t") {
                return String(line[..<index])
            }
            previous = ch
        }
        return line
    }
}
