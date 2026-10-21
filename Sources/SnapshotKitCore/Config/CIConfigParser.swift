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

    var variables: [String: String] = [:]

    init(variables: [String: String] = [:]) {
        self.variables = variables
    }

    // MARK: - Variables

    private static let assignment = try! NSRegularExpression(
        pattern: #"^\s*(?:-\s+)?(?:export\s+)?([A-Za-z_][A-Za-z0-9_-]*)\s*(:(?:\s+|$)|=)(.*)$"#
    )

    /// Collects `KEY: value`, `KEY=value` and `export KEY=value` definitions. First wins.
    static func collectVariables(_ text: String, into variables: inout [String: String]) {
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let ns = line as NSString
            guard let m = assignment.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let key = ns.substring(with: m.range(at: 1))
            var value = MiniYAML.stripComment(ns.substring(with: m.range(at: 3))).trimmingCharacters(in: .whitespaces)
            if value.isEmpty, let item = firstListItem(after: index, in: lines) { value = "[\(item)]" }
            if value.isEmpty || value.hasPrefix("|") || value.hasPrefix(">") || value.hasPrefix("&") || value.hasPrefix("*") { continue }
            if value.hasPrefix("["), value.hasSuffix("]") {
                // Matrix-style lists: use the first entry.
                guard let first = MiniYAML.splitInlineList(String(value.dropFirst().dropLast())).first else { continue }
                value = first
            } else if ns.substring(with: m.range(at: 2)) == "=" {
                // The shell's value is one word: `SCHEME=App xcodebuild …` sets "App".
                value = ShellWords.split(value).first ?? ""
            } else {
                value = MiniYAML.unquote(value)
            }
            if variables[key] == nil { variables[key] = value }
        }
    }

    /// The first item of a block list under a `key:` line (`- '16.2'`), unless the items are
    /// mappings (`- uses: …`).
    private static func firstListItem(after index: Int, in lines: [String]) -> String? {
        guard let next = lines.dropFirst(index + 1).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let item = MiniYAML.stripComment(next).trimmingCharacters(in: .whitespaces)
        guard item.hasPrefix("- "), assignment.firstMatch(in: item, range: NSRange(location: 0, length: (item as NSString).length)) == nil
        else { return nil }
        return String(item.dropFirst(2))
    }

    private static let reference = try! NSRegularExpression(
        pattern: #"\$\{\{\s*(?:env|vars|matrix|inputs)\.([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}|\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#
    )

    /// Expands variable references; unknown references are left untouched.
    func expand(_ string: String) -> String {
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

    /// The text with `#` comments removed (YAML and shell share them), so a commented-out
    /// setting doesn't count.
    static func withoutComments(_ text: String) -> String {
        text.components(separatedBy: .newlines).map(MiniYAML.stripComment).joined(separator: "\n")
    }

    // MARK: - Logical lines

    /// Joins backslash continuations and YAML-folded flag lines (`-scheme X` on its own line)
    /// so each command is one string.
    static func logicalLines(_ text: String) -> [(line: String, index: Int)] {
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
        // Bare action words on their own line (`test`) are also continuations.
        if actionWords.contains(next) { return true }
        // `-scheme App` continues a folded command; `- run tests` is a new YAML list item.
        guard next.hasPrefix("-"), next.count > 1 else { return false }
        return next[next.index(after: next.startIndex)].isLetter
    }

    static let actionWords: Set<String> = ["test", "build", "build-for-testing", "test-without-building", "clean", "analyze", "archive"]

    // MARK: - xcodebuild invocations

    func invocations(in text: String) -> [Invocation] {
        let lines = Self.logicalLines(text)
        let rawLines = text.components(separatedBy: .newlines)
        let outline = YAMLOutline(text)
        var found: [Invocation] = []
        for (fullLine, index) in lines {
            // Without a commented-out command, nor the YAML around one (`- "cd ios && xcodebuild …"`).
            let line = Self.shellCommand(MiniYAML.stripComment(fullLine))
            // Every call on the line (`xcodebuild -version && xcodebuild test …`), also by its full path.
            let calls = Self.xcodebuildCall.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
            for call in calls {
                let start = Range(call.range, in: line)!.lowerBound
                // GitHub replaces `${{ … }}` before the shell splits the line.
                var words = ShellWords.split(ShellWords.firstCommand(expandingExpressions(String(line[start...]))))
                guard words.first == "xcodebuild" else { continue }
                words.removeFirst()
                var invocation = parseArguments(words.map(expand))

                // What runs before it on its line (`cd ios && pod install && `), less the folder it
                // is called from (`/usr/bin/`). In a subshell (`(cd ios && xcodebuild …)`), what runs before
                // it in there too.
                let prefix = String(line[..<start]).replacingOccurrences(of: #"[^\s;&|(`"']*$"#, with: "", options: .regularExpression)
                let moves = folders(around: index, in: outline) + folderChanges(inLine: prefix, enteringOpenSubshells: true)
                invocation.workingDirectory = Self.path(following: moves)

                // Score: prefer `test`, and anything that mentions snapshots nearby.
                if invocation.actions.contains("test") || invocation.actions.contains("test-without-building") { invocation.score += 4 }
                if invocation.actions.contains("build-for-testing") { invocation.score += 1 }
                let context = rawLines[max(0, index - 25)...min(rawLines.count - 1, index)].joined(separator: "\n").lowercased()
                if line.lowercased().contains("snapshot") { invocation.score += 3 } else if context.contains("snapshot") { invocation.score += 2 }
                found.append(invocation)
            }
        }
        return found
    }

    /// `xcodebuild` as a command: at the start, after a separator or quote, or at the end of a path.
    private static let xcodebuildCall = try! NSRegularExpression(pattern: #"(?<=^|[\s;&|(`"'/])xcodebuild(?=\s|$)"#)
    /// A GitHub Actions expression, `${{ env.NAME }}`.
    private static let expression = try! NSRegularExpression(pattern: #"\$\{\{[^}]*\}\}"#)

    /// `command` with its GitHub expressions replaced by their values, and the spaces taken out of
    /// those it can't resolve (`${{ secrets.X }}`), so each stays one unresolved word.
    func expandingExpressions(_ command: String) -> String {
        let ns = command as NSString
        var result = command
        for match in Self.expression.matches(in: command, range: NSRange(location: 0, length: ns.length)).reversed() {
            let expression = ns.substring(with: match.range)
            let value = expand(expression)
            let replacement = value == expression ? expression.filter { !$0.isWhitespace } : value
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    func parseArguments(_ words: [String]) -> Invocation {
        var inv = Invocation(arguments: words, actions: [])
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
                } else if Self.actionWords.contains(word) {
                    inv.actions.append(word)
                }
            }
            i += 1
        }
        return inv
    }

    // MARK: - Working directory

    /// How a command moves the shell: to a folder (`cd`, or a `working-directory`), to one keeping
    /// where it was (`pushd`), or back there (`popd`).
    enum FolderChange: Equatable {
        case cd(String)
        case pushd(String)
        case popd
    }

    /// The folders the shell moves to before line `index` runs, in order, as written: GitHub Actions'
    /// `working-directory` (the step's, else its job's or the workflow's `defaults.run`), then every
    /// `cd` before it in the same shell (earlier in its `run:` block or `script:` list, after GitLab's
    /// `before_script:` of the job, else of `default:`). In a shell script, every `cd` before it.
    func folders(around index: Int, in outline: YAMLOutline) -> [FolderChange] {
        func child(_ key: String, of scope: Int) -> Int? { outline.children(of: scope).first { outline.key($0) == key } }
        guard outline.children(of: -1).contains(where: { outline.key($0) != nil }) else {
            return folderChanges(before: index, in: outline.lines.indices, of: outline)        // a shell script
        }
        let ancestors = outline.ancestors(of: index)
        var folders: [FolderChange] = []
        for scope in (outline.isListItem(index) ? [index] : []) + ancestors + [-1] {
            if scope >= 0, outline.isListItem(scope), let step = outline.value(at: ["working-directory"], under: scope) {
                folders.append(.cd(expand(step)))
                break
            }
            if let defaults = outline.value(at: ["defaults", "run", "working-directory"], under: scope) {
                folders.append(.cd(expand(defaults)))
                break
            }
        }
        // The script's key line, which may be the command itself (`script: xcodebuild test …`).
        let scriptKeys = ["run", "script", "before_script"]
        guard let script = ([index] + ancestors).first(where: { scriptKeys.contains(outline.key($0) ?? "") }) else { return folders }
        if outline.key(script) == "script" {
            let job = ancestors.first { $0 < script } ?? -1     // the next one out
            let before = child("before_script", of: job) ?? child("default", of: -1).flatMap { child("before_script", of: $0) }
                ?? child("before_script", of: -1)
            if let before {
                let block = outline.block(of: before)
                folders += folderChanges(before: block.upperBound, in: block, of: outline)
            }
        }
        return folders + folderChanges(before: index, in: min(script + 1, index)..<outline.block(of: script).upperBound, of: outline)
    }

    /// A shell function: its name, and its lines from its header to its closing brace.
    private struct ShellFunction {
        var name: String
        var lines: ClosedRange<Int>
    }

    /// The moves of the shell running the lines in `scope` before it gets to line `index`, in order.
    /// A shell function's body runs where the function is called, not where it is written: for a
    /// line in one, the moves before the function's first call, then those of its body before the line.
    private func folderChanges(before index: Int, in scope: Range<Int>, of outline: YAMLOutline) -> [FolderChange] {
        let functions = Self.functions(in: scope, of: outline)
        func moves(before index: Int, outside called: Set<String>) -> [FolderChange] {
            guard let function = functions.last(where: { $0.lines.contains(index) }), !called.contains(function.name) else {
                return (scope.lowerBound..<index).filter { i in !functions.contains { $0.lines.contains(i) } }
                    .flatMap { folderChanges(inLine: outline.lines[$0]) }
            }
            let body = (function.lines.lowerBound..<index).flatMap { folderChanges(inLine: outline.lines[$0]) }
            let called = called.union([function.name])
            for line in scope where !function.lines.contains(line) {
                let commands = ShellWords.commands(expandingExpressions(Self.shellCommand(outline.lines[line])))
                guard let call = commands.firstIndex(where: { ShellWords.split($0).first == function.name }) else { continue }
                return moves(before: line, outside: called) + commands[..<call].flatMap(folderChanges(inCommand:)) + body
            }
            return moves(before: function.lines.lowerBound, outside: called) + body     // not called in sight
        }
        return moves(before: index, outside: [])
    }

    /// The shell functions declared on the lines in `scope`.
    private static func functions(in scope: Range<Int>, of outline: YAMLOutline) -> [ShellFunction] {
        var functions: [ShellFunction] = []
        var open: (name: String, start: Int)?
        var braces = 0              // open in its body
        var bodyFollows = false     // a `name()` line without its `{`
        for i in scope {
            let command = shellCommand(outline.lines[i])
            let change = command.count(where: { $0 == "{" }) - command.count(where: { $0 == "}" })
            if open != nil {
                if bodyFollows {
                    bodyFollows = false
                    guard command.hasPrefix("{") else {
                        open = nil
                        continue
                    }
                }
                braces = max(braces + change, 0)
            } else if let header = functionHeader.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) {
                let name = header.range(at: 1).location == NSNotFound ? header.range(at: 2) : header.range(at: 1)
                open = ((command as NSString).substring(with: name), i)
                braces = max(change, 0)
                bodyFollows = !command.contains("{")
                if bodyFollows { continue }
            } else {
                continue
            }
            if braces == 0, let function = open {
                functions.append(ShellFunction(name: function.name, lines: function.start...i))
                open = nil
            }
        }
        if let function = open, !bodyFollows, !scope.isEmpty {
            functions.append(ShellFunction(name: function.name, lines: function.start...(scope.upperBound - 1)))
        }
        return functions
    }

    /// `name() {`, `function name {`: a shell function starts.
    private static let functionHeader = try! NSRegularExpression(pattern: #"^(?:function\s+([\w.-]+)|([\w.-]+)\s*\(\s*\))"#)

    /// A line of a CI file as the shell gets it: without a list marker or a `run:` or `script:` key
    /// in front, nor the quotes of the YAML scalar after them (`- 'cd ios'`).
    static func shellCommand(_ line: String) -> String {
        let text = line.trimmingCharacters(in: .whitespaces)
        let command = text.replacingOccurrences(of: #"^(?:-\s+)?(?:(?:run|script|before_script):\s+)?"#, with: "", options: .regularExpression)
        // Only a YAML value is quoted as a whole: a shell line can start and end with quotes of its own.
        return command == text ? command : MiniYAML.unquote(command)
    }

    /// The moves of the commands of a line of a CI file, in order. GitHub replaces `${{ … }}` before
    /// the shell splits the line, so `cd ${{ env.APP_DIR }}` is one `cd`. A function's header in
    /// front (`build() { cd ios && …`) isn't a command: what follows it is the function's body.
    /// `enteringOpenSubshells` as for `ShellWords.commands`.
    private func folderChanges(inLine line: String, enteringOpenSubshells: Bool = false) -> [FolderChange] {
        let command = Self.shellCommand(line).replacingOccurrences(of: Self.bodyStart, with: "", options: .regularExpression)
        return ShellWords.commands(expandingExpressions(command), enteringOpenSubshells: enteringOpenSubshells)
            .flatMap(folderChanges(inCommand:))
    }

    /// `name() {`, `function name {` or the `{` of a group in front of a line's commands.
    private static let bodyStart = #"^(?:(?:function\s+[\w.-]+(?:\s*\(\s*\))?|[\w.-]+\s*\(\s*\))\s*)?\{(?=\s|$)"#

    /// How one command moves the shell, if it does: `cd` and `pushd` (to the folder with its
    /// variables expanded), and `popd`.
    private func folderChanges(inCommand command: String) -> [FolderChange] {
        let words = ShellWords.split(command)
        let folder = words.dropFirst().first { !$0.hasPrefix("-") }.map(expand) ?? "~"
        switch words.first {
        case "cd": return [.cd(folder)]
        case "pushd": return [.pushd(folder)]
        case "popd": return [.popd]
        default: return []
        }
    }

    /// What the CI's checkout folder is called: where a job starts.
    private static let checkoutFolders = ["$CI_PROJECT_DIR", "${CI_PROJECT_DIR}", "$GITHUB_WORKSPACE", "${GITHUB_WORKSPACE}",
                                          "${{ github.workspace }}", "${{github.workspace}}"]

    /// Where following `changes` one after the other from the repository's root leads, relative to
    /// it, as the shell goes; nil for the root itself. A folder outside the repository or unknown (a
    /// variable not defined in sight, `$(dirname "$0")/..`, `cd -`, a `popd` without its `pushd`)
    /// is taken to lead back to the root: scripts go there that way, and a later `cd ios` still counts.
    static func path(following changes: [FolderChange]) -> String? {
        var components: [String] = []
        var stack: [[String]] = []      // where each `pushd` left
        for change in changes {
            switch change {
            case .cd(let folder):
                components = path(following: folder, from: components)
            case .pushd(let folder):
                stack.append(components)
                components = path(following: folder, from: components)
            case .popd:
                components = stack.popLast() ?? []
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    /// Where a `cd` to `folder` from `components` leads.
    private static func path(following folder: String, from components: [String]) -> [String] {
        var folder = folder
        var components = components
        if let root = checkoutFolders.first(where: { folder == $0 || folder.hasPrefix($0 + "/") }) {
            folder = "." + folder.dropFirst(root.count)
            components = []
        }
        guard isResolved(folder), !folder.hasPrefix("/"), !folder.hasPrefix("~"), folder != "-" else { return [] }
        for component in folder.split(separator: "/") where component != "." {
            if component != ".." {
                components.append(String(component))
            } else if components.popLast() == nil {
                break
            }
        }
        return components
    }

    // MARK: - Xcode version

    /// Finds the Xcode version (or Xcode path) CI selects.
    func xcodeSelection(in text: String) -> (version: String?, developerDir: String?) {
        let expanded = expand(Self.withoutComments(text))
        for pattern in Self.xcodeVersionPatterns {
            if let v = Self.firstCapture(pattern, in: expanded) { return (v, nil) }
        }
        for pattern in Self.xcodePathPatterns {
            if let dir = Self.firstCapture(pattern, in: expanded), Self.isResolved(dir) { return (nil, dir) }
        }
        return (nil, nil)
    }

    private static let xcodeVersionPatterns = searchPatterns([
        #"xcode-version:\s*['"]?([0-9]+(?:\.[0-9]+)*)"#,
        #"Xcode[_-]?([0-9]+(?:\.[0-9]+)*)\.app"#,
        #"\b[A-Z_]*XCODE[A-Z_]*VERSION[A-Z_]*\s*[:=]\s*['"]?(?:Xcode[_ -]?)?([0-9]+(?:\.[0-9]+)*)"#,
        #"\bxcodes\s+(?:select|use|install)\s+['"]?([0-9]+(?:\.[0-9]+)*)"#,
        #"\bxcversion\s+select\s+['"]?([0-9]+(?:\.[0-9]+)*)"#,
        #"image:\s*\S*xcode[:_-]([0-9]+(?:\.[0-9]+)*)"#,
    ])
    private static let xcodePathPatterns = searchPatterns([
        #"DEVELOPER_DIR\s*[:=]\s*['"]?([^'"\s]+)"#,
        #"xcode-select\s+(?:-s|--switch)\s+['"]?([^'"\s]+)"#,
    ])

    // MARK: - Base branch

    /// The branch merge/pull requests target, when CI restricts it.
    func baseBranch(in text: String) -> String? {
        let expanded = expand(Self.withoutComments(text))
        for pattern in Self.mergeRequestTargetPatterns {
            if let gitlab = Self.firstCapture(pattern, in: expanded) { return gitlab }
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

    private static let mergeRequestTargetPatterns = searchPatterns([
        #"\$CI_MERGE_REQUEST_TARGET_BRANCH_NAME\s*==\s*["']([^"']+)["']"#,
        #"\$CI_MERGE_REQUEST_TARGET_BRANCH_NAME\s*=~\s*/\^?([A-Za-z0-9._/-]+?)\$?/"#,
    ])

    // MARK: - Whole documents

    public struct Extraction: Sendable {
        public var config = SnapshotConfig()
        public var invocation: Invocation?
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
            let remote = documents.flatMap { remoteIncludes(in: $0.text) }
            if remote.isEmpty {
                out.notes.append("No `xcodebuild` invocation found in \(documents.map { "`\($0.name)`" }.joined(separator: ", ")).")
            } else {
                out.notes.append("The test job comes from \(remote.map { "`\($0)`" }.joined(separator: ", ")), which SnapshotKit can’t read. "
                                 + "Settings were taken from CI variables; set anything missing in `.snapshotkit.yml`.")
            }
        }

        // Settings the command line didn't give (or there was none): common CI variable names.
        for (field, value, name) in parser.variableSettings(variables) {
            let key = field.rawValue
            guard config.sources[key] == nil else { continue }
            let source = (documents.first { $0.text.range(of: #"\b"# + name + #"\s*[:=]"#, options: .regularExpression) != nil }?.name
                          ?? documents.first?.name ?? "CI") + " · " + name
            switch field {
            case .scheme: config.scheme = value
            case .project: config.project = value
            case .workspace: config.workspace = value
            case .testPlan: config.testPlan = value
            case .deviceName: config.deviceName = value
            case .osVersion: config.osVersion = value
            default: continue
            }
            config.sources[key] = source
        }

        // Xcode selection: prefer the document that holds the chosen invocation.
        let ordered = documents.filter { $0.name == best?.1 } + documents.filter { $0.name != best?.1 }
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

    // MARK: - CI variables

    /// Includes from elsewhere (another project, a URL, a template or component): their jobs,
    /// often the actual test command, aren't in this repository.
    public static func remoteIncludes(in text: String) -> [String] {
        var found: [String] = []
        let lines = text.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "- ", with: "")
            for key in ["project:", "remote:", "template:", "component:"] where t.hasPrefix(key) {
                var item = MiniYAML.unquote(String(t.dropFirst(key.count)).trimmingCharacters(in: .whitespaces))
                if key == "project:" {
                    // The file usually follows within the same list item.
                    for next in lines.dropFirst(i + 1).prefix(4) {
                        let n = next.trimmingCharacters(in: .whitespaces)
                        if n.hasPrefix("- ") { break }
                        if n.hasPrefix("file:") {
                            item += " (" + MiniYAML.unquote(String(n.dropFirst(5)).trimmingCharacters(in: .whitespaces)) + ")"
                        }
                    }
                }
                if !item.isEmpty { found.append(item) }
            }
        }
        return found
    }

    /// Settings taken from conventional variable names, for when the `xcodebuild` command is out of
    /// sight (in a shared template) or leaves something out. Only fully resolved values count.
    /// Returns (field, value, variable name), most specific variable first per field.
    func variableSettings(_ variables: [String: String]) -> [(SnapshotConfig.Field, String, String)] {
        let resolved = variables.compactMap { name, raw -> (String, String)? in
            let value = MiniYAML.unquote(expand(raw)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty || !Self.isResolved(value) ? nil : (name.uppercased(), value)
        }
        .sorted { $0.0 < $1.0 }
        func first(_ match: (String, String) -> Bool) -> (String, String)? { resolved.first { match($0.0, $0.1) } }
        var out: [(SnapshotConfig.Field, String, String)] = []

        // Scheme: one named for snapshot tests, then for tests, then the plain scheme.
        if let (name, value) = first({ n, _ in n.contains("SNAPSHOT") && n.contains("SCHEME") })
            ?? first({ n, _ in n.contains("TEST") && n.contains("SCHEME") })
            ?? first({ n, _ in n == "SCHEME" || n.hasSuffix("_SCHEME") }) {
            out.append((.scheme, value, name))
        }
        if let (name, value) = first({ _, v in v.hasSuffix(".xcworkspace") && !v.contains("/") })
            ?? first({ _, v in v.hasSuffix(".xcworkspace") }) {
            out.append((.workspace, value, name))
        }
        if let (name, value) = first({ n, v in v.hasSuffix(".xcodeproj") && n.contains("PROJECT") && !v.contains("/") })
            ?? first({ _, v in v.hasSuffix(".xcodeproj") }) {
            out.append((.project, value, name))
        }
        if let (name, value) = first({ n, _ in n.contains("TEST_PLAN") || n.contains("TESTPLAN") }) {
            out.append((.testPlan, value, name))
        }
        // Device: "iPhone 16 Pro (18.0)", "iPhone 16 Pro,OS=18.0", a full destination, or a name.
        if let (name, value) = first({ n, _ in (n.contains("SIMULATOR") || n.contains("DEVICE") || n.contains("DESTINATION"))
            && !n.contains("DEVELOPER") && !n.contains("OS_VERSION") }) {
            if value.contains("name=") {
                let d = Destination.parse(value)
                if let device = d.name { out.append((.deviceName, device, name)) }
                if let os = d.os { out.append((.osVersion, os, name)) }
            } else if let m = value.range(of: #"^(.+?)\s*\(([0-9]+(?:\.[0-9]+)*)\)$"#, options: .regularExpression) {
                let text = String(value[m])
                let open = text.lastIndex(of: "(")!
                out.append((.deviceName, text[..<open].trimmingCharacters(in: .whitespaces), name))
                out.append((.osVersion, String(text[text.index(after: open)...].dropLast()), name))
            } else if let comma = value.range(of: ",OS=", options: .caseInsensitive) {
                out.append((.deviceName, String(value[..<comma.lowerBound]), name))
                out.append((.osVersion, String(value[comma.upperBound...]), name))
            } else if value.range(of: #"^(iPhone|iPad|Apple TV|Apple Watch|Apple Vision)"#, options: .regularExpression) != nil {
                out.append((.deviceName, value, name))
            }
        }
        if !out.contains(where: { $0.0 == .osVersion }),
           let (name, value) = first({ n, v in (n.contains("OS_VERSION") || n.contains("SIMULATOR_OS") || n.contains("RUNTIME"))
               && !n.contains("XCODE") && v.range(of: #"^[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil }) {
            out.append((.osVersion, value, name))
        }
        return out
    }

    /// Shell scripts a CI document invokes (e.g. `./scripts/test.sh`), so their
    /// `xcodebuild` calls can be read too.
    public static func referencedScripts(in text: String) -> [String] {
        let ns = text as NSString
        var seen: [String] = []
        for m in scriptReference.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var path = ns.substring(with: m.range(at: 1))
            if path.hasPrefix("./") { path.removeFirst(2) }
            if !seen.contains(path) { seen.append(path) }
        }
        return seen
    }

    private static let scriptReference = try! NSRegularExpression(pattern: #"(?:^|[\s"'])((?:\./)?[A-Za-z0-9_./-]+\.sh)\b"#)

    /// Case-insensitive, `^` and `$` at every line.
    private static func searchPatterns(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive, .anchorsMatchLines]) }
    }

    private static func firstCapture(_ regex: NSRegularExpression, in text: String) -> String? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
