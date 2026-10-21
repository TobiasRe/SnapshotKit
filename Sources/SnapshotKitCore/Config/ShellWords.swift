import Foundation

/// Minimal POSIX-shell word splitting (quotes and backslashes), enough to read
/// command lines out of CI scripts.
enum ShellWords {
    static func split(_ line: String) -> [String] {
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

    /// The commands of a line that run in its shell, in order: split at unquoted `&&`, `||`, `;`,
    /// `|` and `&`, without those in a `( … )` subshell, whose `cd` doesn't move the shell.
    /// A `$( … )` stays part of the word it is in. With `enteringOpenSubshells`, for the start of a
    /// line up to a command (`cd ios && (cd App && `), a subshell still open at its end is where the
    /// command runs: the commands before it in there count too.
    static func commands(_ line: String, enteringOpenSubshells: Bool = false) -> [String] {
        var commands: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0                   // parentheses open: a subshell's, or a `$(`'s
        var subshell: String.Index?     // the `(` of the current command, a `( … )`
        var previous: Character = " "
        func finish() {
            let command = current.trimmingCharacters(in: .whitespaces)
            if subshell == nil, !command.isEmpty { commands.append(command) }
            current = ""
            subshell = nil
        }
        for (index, ch) in zip(line.indices, line) {
            defer { previous = ch }
            if let q = quote {
                if ch == q && previous != "\\" { quote = nil }
                current.append(ch)
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
            case "(":
                if depth == 0, previous != "$", current.allSatisfy(\.isWhitespace) { subshell = index }
                depth += 1
            case ")":
                depth = max(depth - 1, 0)
            case "&", "|", ";":
                if depth == 0 {
                    finish()
                    continue
                }
            default:
                break
            }
            current.append(ch)
        }
        if enteringOpenSubshells, depth > 0, let open = subshell {
            return commands + Self.commands(String(line[line.index(after: open)...]), enteringOpenSubshells: true)
        }
        finish()
        return commands
    }

    /// Cuts a command line at the first unquoted shell control operator (`|`, `&&`, `;`, `>` …), or
    /// the `)` ending the subshell it runs in, so piping into a formatter does not leak arguments.
    static func firstCommand(_ line: String) -> String {
        var quote: Character?
        var depth = 0               // parentheses open in it, a `$(`'s
        var previous: Character = " "
        for (index, ch) in zip(line.indices, line) {
            if let q = quote {
                if ch == q && previous != "\\" { quote = nil }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "(" {
                depth += 1
            } else if ch == ")", depth > 0 {
                depth -= 1
            } else if ch == "|" || ch == ";" || ch == ">" || ch == "<" || ch == ")" || (ch == "&" && previous == "&") {
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
