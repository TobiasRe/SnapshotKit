import Foundation

/// Extracts test settings from CI definitions (GitLab CI, GitHub Actions, or shell
/// scripts they call) by reading `xcodebuild` invocations and the variables around them.
///
/// CI files vary wildly, so this is a tolerant text scanner rather than a YAML parser:
/// it resolves `$VAR`, `${VAR}` and `${{ env.VAR }}` references from any `KEY: value`
/// or `KEY=value` definitions it can see.
public struct CIConfigParser {
    public struct Invocation: Equatable, Sendable {
        public var arguments: [String]
        public var actions: [String]
        public var scheme: String?
        public var project: String?
        public var workspace: String?
        public var testPlan: String?
        public var destination: Destination?
        public var onlyTesting: [String] = []
        public var skipTesting: [String] = []
        public var workingDirectory: String?
        /// Higher is a better match for "the snapshot test job".
        public var score: Int = 0
    }

    public struct Destination: Equatable, Sendable {
        public var platform: String?
        public var name: String?
        public var os: String?

        public static func parse(_ spec: String) -> Destination {
            var d = Destination()
            for pair in spec.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                switch kv[0].lowercased() {
                case "platform": d.platform = kv[1]
                case "name": d.name = kv[1]
                case "os": d.os = kv[1]
                default: break
                }
            }
            return d
        }
    }

    public struct Document: Sendable {
        public var name: String
        public var text: String
        public init(name: String, text: String) {
            self.name = name
            self.text = text
        }
    }

    public var variables: [String: String] = [:]

    public init(variables: [String: String] = [:]) {
        self.variables = variables
    }

    // MARK: - Variables

    private static let assignment = try! NSRegularExpression(
        pattern: #"^\s*(?:-\s+)?(?:export\s+)?([A-Za-z_][A-Za-z0-9_-]*)\s*(?::\s+|=)(.*)$"#
    )

    /// Collects `KEY: value`, `KEY=value` and `export KEY=value` definitions. First wins.
    public static func collectVariables(_ text: String, into variables: inout [String: String]) {
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let m = assignment.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let key = ns.substring(with: m.range(at: 1))
            var value = MiniYAML.stripComment(ns.substring(with: m.range(at: 2))).trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.hasPrefix("|") || value.hasPrefix(">") || value.hasPrefix("&") || value.hasPrefix("*") { continue }
            if value.hasPrefix("["), value.hasSuffix("]") {
                // Matrix-style lists: use the first entry.
                guard let first = MiniYAML.splitInlineList(String(value.dropFirst().dropLast())).first else { continue }
                value = first
            } else {
                value = MiniYAML.unquote(value)
            }
            if variables[key] == nil { variables[key] = value }
        }
    }

    private static let reference = try! NSRegularExpression(
        pattern: #"\$\{\{\s*(?:env|vars|matrix|inputs)\.([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}|\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#
    )

    /// Expands variable references; unknown references are left untouched.
    public func expand(_ string: String) -> String {
        var current = string
        for _ in 0..<5 {
            let ns = current as NSString
            let matches = Self.reference.matches(in: current, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { break }
            var result = current
            var changed = false
            for m in matches.reversed() {
                let name = (1...3).lazy.compactMap { i -> String? in
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? nil : ns.substring(with: r)
                }.first
                if let name, let value = variables[name] {
                    result = (result as NSString).replacingCharacters(in: m.range, with: value)
                    changed = true
                }
            }
            current = result
            if !changed { break }
        }
        return current
    }

    static func isResolved(_ value: String) -> Bool { !value.contains("$") }

    // MARK: - Logical lines

    /// Joins backslash continuations and YAML-folded flag lines (`-scheme X` on its own line)
    /// so each command is one string.
    public static func logicalLines(_ text: String) -> [(line: String, index: Int)] {
        let raw = text.components(separatedBy: .newlines)
        var result: [(String, Int)] = []
        var i = 0
        while i < raw.count {
            var line = raw[i]
            let start = i
            while true {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix("\\") {
                    guard i + 1 < raw.count else { break }
                    line = String(trimmed.dropLast()) + " " + raw[i + 1].trimmingCharacters(in: .whitespaces)
                    i += 1
                    continue
                }
                if line.contains("xcodebuild"), i + 1 < raw.count {
                    let next = raw[i + 1].trimmingCharacters(in: .whitespaces)
                    if isFoldedContinuation(next) {
                        line += " " + next
                        i += 1
                        continue
                    }
                }
                break
            }
            result.append((line, start))
            i += 1
        }
        return result
    }

    private static func isFoldedContinuation(_ next: String) -> Bool {
        // `-scheme App` continues a folded command; `- run tests` is a new YAML list item.
        guard next.hasPrefix("-"), next.count > 1 else { return false }
        let second = next[next.index(after: next.startIndex)]
        if second.isLetter { return true }
        // Bare action words on their own line (`test`) are also continuations.
        return false
    }

    // MARK: - xcodebuild invocations

    public func invocations(in text: String) -> [Invocation] {
        let lines = Self.logicalLines(text)
        let rawLines = text.components(separatedBy: .newlines)
        var found: [Invocation] = []
        for (line, index) in lines {
            guard let range = line.range(of: #"(^|[\s;&|(`"'])xcodebuild(\s|$)"#, options: .regularExpression) else { continue }
            let prefix = String(line[..<range.lowerBound])
            var command = String(line[range.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ;&|(`\"'"))
            command = ShellWords.firstCommand(command)
            var words = ShellWords.split(command)
            guard words.first == "xcodebuild" else { continue }
            words.removeFirst()
            var invocation = parseArguments(words.map(expand))

            if let cd = prefix.range(of: #"cd\s+([^\s;&]+)\s*&&\s*$"#, options: .regularExpression) {
                let dir = String(prefix[cd]).replacingOccurrences(of: #"^cd\s+|\s*&&\s*$"#, with: "", options: .regularExpression)
                invocation.workingDirectory = expand(MiniYAML.unquote(dir))
            }

            // Score: prefer `test`, and anything that mentions snapshots nearby.
            if invocation.actions.contains("test") || invocation.actions.contains("test-without-building") { invocation.score += 4 }
            if invocation.actions.contains("build-for-testing") { invocation.score += 1 }
            let context = rawLines[max(0, index - 25)...min(rawLines.count - 1, index)].joined(separator: "\n").lowercased()
            if line.lowercased().contains("snapshot") { invocation.score += 3 } else if context.contains("snapshot") { invocation.score += 2 }
            found.append(invocation)
        }
        return found
    }

    func parseArguments(_ words: [String]) -> Invocation {
        var inv = Invocation(arguments: words, actions: [])
        let actionWords: Set<String> = ["test", "build", "build-for-testing", "test-without-building", "clean", "analyze", "archive"]
        var i = 0
        func next() -> String? {
            i += 1
            return i < words.count ? words[i] : nil
        }
        func resolved(_ value: String?) -> String? {
            guard let value, Self.isResolved(value), !value.isEmpty else { return nil }
            return value
        }
        while i < words.count {
            let word = words[i]
            switch word {
            case "-scheme": inv.scheme = resolved(next())
            case "-project": inv.project = resolved(next())
            case "-workspace": inv.workspace = resolved(next())
            case "-testPlan": inv.testPlan = resolved(next())
            case "-destination":
                if let spec = resolved(next()) { inv.destination = Destination.parse(spec) }
            case "-only-testing": if let v = resolved(next()) { inv.onlyTesting.append(v) }
            case "-skip-testing": if let v = resolved(next()) { inv.skipTesting.append(v) }
            default:
                if word.hasPrefix("-only-testing:") {
                    if let v = resolved(String(word.dropFirst("-only-testing:".count))) { inv.onlyTesting.append(v) }
                } else if word.hasPrefix("-skip-testing:") {
                    if let v = resolved(String(word.dropFirst("-skip-testing:".count))) { inv.skipTesting.append(v) }
                } else if actionWords.contains(word) {
                    inv.actions.append(word)
                }
            }
            i += 1
        }
        return inv
    }

    // MARK: - Xcode version

    /// Finds the Xcode version (or Xcode path) CI selects.
    public func xcodeSelection(in text: String) -> (version: String?, developerDir: String?) {
        let expanded = expand(text)
        let patterns = [
            #"xcode-version:\s*['"]?([0-9]+(?:\.[0-9]+)*)"#,
            #"Xcode[_-]?([0-9]+(?:\.[0-9]+)*)\.app"#,
            #"\b[A-Z_]*XCODE[A-Z_]*VERSION[A-Z_]*\s*[:=]\s*['"]?([0-9]+(?:\.[0-9]+)*)"#,
            #"\bxcodes\s+(?:select|use|install)\s+['"]?([0-9]+(?:\.[0-9]+)*)"#,
            #"\bxcversion\s+select\s+['"]?([0-9]+(?:\.[0-9]+)*)"#,
            #"image:\s*\S*xcode[:_-]([0-9]+(?:\.[0-9]+)*)"#,
        ]
        for pattern in patterns {
            if let v = firstCapture(pattern, in: expanded) { return (v, nil) }
        }
        if let dir = firstCapture(#"DEVELOPER_DIR\s*[:=]\s*['"]?([^'"\s]+)"#, in: expanded), Self.isResolved(dir) {
            return (nil, dir)
        }
        if let dir = firstCapture(#"xcode-select\s+(?:-s|--switch)\s+['"]?([^'"\s]+)"#, in: expanded), Self.isResolved(dir) {
            return (nil, dir)
        }
        return (nil, nil)
    }

    // MARK: - Base branch

    /// The branch merge/pull requests target, when CI restricts it.
    public func baseBranch(in text: String) -> String? {
        let expanded = expand(text)
        if let gitlab = firstCapture(#"\$CI_MERGE_REQUEST_TARGET_BRANCH_NAME\s*==\s*["']([^"']+)["']"#, in: expanded) {
            return gitlab
        }
        if let gitlab = firstCapture(#"\$CI_MERGE_REQUEST_TARGET_BRANCH_NAME\s*=~\s*/\^?([A-Za-z0-9._/-]+?)\$?/"#, in: expanded) {
            return gitlab
        }
        // GitHub: `pull_request:` followed by `branches:` as an inline or block list.
        let lines = expanded.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pull_request:") || trimmed.hasPrefix("pull_request_target:") else { continue }
            let indent = line.prefix { $0 == " " }.count
            var j = i + 1
            while j < lines.count {
                let l = lines[j]
                let t = l.trimmingCharacters(in: .whitespaces)
                let lIndent = l.prefix { $0 == " " }.count
                if !t.isEmpty && lIndent <= indent { break }
                if t.hasPrefix("branches:") {
                    let rest = t.dropFirst("branches:".count).trimmingCharacters(in: .whitespaces)
                    var candidates: [String] = []
                    if rest.hasPrefix("[") {
                        candidates = MiniYAML.splitInlineList(String(rest.dropFirst().dropLast()))
                    } else if !rest.isEmpty {
                        candidates = [MiniYAML.unquote(rest)]
                    } else {
                        var k = j + 1
                        while k < lines.count {
                            let item = lines[k].trimmingCharacters(in: .whitespaces)
                            guard item.hasPrefix("- ") else { break }
                            candidates.append(MiniYAML.unquote(String(item.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                            k += 1
                        }
                    }
                    if let branch = candidates.first(where: { !$0.contains("*") && !$0.hasPrefix("!") }) { return branch }
                }
                j += 1
            }
        }
        return nil
    }

    // MARK: - Whole documents

    public struct Extraction: Sendable {
        public var config = SnapshotConfig()
        public var invocation: Invocation?
        public var invocationSource: String?
        public var notes: [String] = []
    }

    /// Combines several CI documents: variables are shared (GitLab includes behave this way),
    /// the best-scoring `xcodebuild` invocation wins.
    public static func extract(from documents: [Document]) -> Extraction {
        var variables: [String: String] = [:]
        for doc in documents { collectVariables(doc.text, into: &variables) }
        let parser = CIConfigParser(variables: variables)
        var out = Extraction()

        var best: (Invocation, String)?
        for doc in documents {
            for inv in parser.invocations(in: doc.text) where best == nil || inv.score > best!.0.score {
                best = (inv, doc.name)
            }
        }
        var config = SnapshotConfig()
        if let (inv, source) = best {
            out.invocation = inv
            out.invocationSource = source
            func set<T>(_ kp: WritableKeyPath<SnapshotConfig, T?>, _ value: T?, _ field: SnapshotConfig.Field) {
                guard let value else { return }
                config[keyPath: kp] = value
                config.sources[field.rawValue] = source
            }
            set(\.scheme, inv.scheme, .scheme)
            set(\.project, inv.project, .project)
            set(\.workspace, inv.workspace, .workspace)
            set(\.testPlan, inv.testPlan, .testPlan)
            set(\.platform, inv.destination?.platform, .platform)
            set(\.deviceName, inv.destination?.name, .deviceName)
            set(\.osVersion, inv.destination?.os, .osVersion)
            set(\.workingDirectory, inv.workingDirectory, .workingDirectory)
            if !inv.onlyTesting.isEmpty {
                config.onlyTesting = inv.onlyTesting
                config.sources[SnapshotConfig.Field.onlyTesting.rawValue] = source
            }
            if !inv.skipTesting.isEmpty {
                config.skipTesting = inv.skipTesting
                config.sources[SnapshotConfig.Field.skipTesting.rawValue] = source
            }
        } else if !documents.isEmpty {
            out.notes.append("No xcodebuild invocation found in \(documents.map(\.name).joined(separator: ", ")).")
        }

        // Xcode selection: prefer the document that holds the chosen invocation.
        let ordered = documents.sorted { a, _ in a.name == best?.1 }
        for doc in ordered {
            let selection = parser.xcodeSelection(in: doc.text)
            if let v = selection.version {
                config.xcodeVersion = v
                config.sources[SnapshotConfig.Field.xcodeVersion.rawValue] = doc.name
                break
            }
            if let d = selection.developerDir, config.developerDir == nil {
                config.developerDir = d
                config.sources[SnapshotConfig.Field.developerDir.rawValue] = doc.name
            }
        }
        for doc in ordered {
            if let branch = parser.baseBranch(in: doc.text) {
                config.baseBranch = branch
                config.sources[SnapshotConfig.Field.baseBranch.rawValue] = doc.name
                break
            }
        }
        out.config = config
        return out
    }

    /// Shell scripts a CI document invokes (e.g. `./scripts/test.sh`), so their
    /// `xcodebuild` calls can be read too.
    public static func referencedScripts(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?:^|[\s"'])((?:\./)?[A-Za-z0-9_./-]+\.sh)\b"#)
        let ns = text as NSString
        var seen: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var path = ns.substring(with: m.range(at: 1))
            if path.hasPrefix("./") { path.removeFirst(2) }
            if !seen.contains(path) { seen.append(path) }
        }
        return seen
    }

    private func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
