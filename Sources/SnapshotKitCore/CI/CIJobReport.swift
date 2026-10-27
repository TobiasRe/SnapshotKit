import Foundation

/// What a CI job's log says about its test run. The log has no failure messages; the pipeline's test
/// report has those.
public struct CITrace: Equatable, Sendable {
    /// A failing test as xcodebuild lists it at the end of a run.
    public struct Test: Equatable, Sendable {
        /// The target, when xcodebuild groups the list by it.
        public var bundle: String?
        public var suite: [String]
        /// `testCard()`, `card()`.
        public var name: String
    }

    /// The scheme the job tested (`-scheme X` on its `xcodebuild` line).
    public var scheme: String?
    public var failingTests: [Test] = []
    /// The result bundle xcodebuild wrote, on the runner.
    public var resultBundle: String?
    /// The folder the runner checked the project out to, so its paths can be made the repository's.
    public var projectDirectory: String?

    public init(scheme: String? = nil, failingTests: [Test] = [], resultBundle: String? = nil, projectDirectory: String? = nil) {
        self.scheme = scheme
        self.failingTests = failingTests
        self.resultBundle = resultBundle
        self.projectDirectory = projectDirectory
    }

    public init(log: String) {
        let lines = Self.plain(log).components(separatedBy: .newlines)
        var bundle: String?
        var inFailing = false
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if inFailing {
                // `\tTarget:` then `\t\tSuite.test()` (Xcode 16), or `\tSuite.test()`.
                if text.isEmpty || text.hasPrefix("**") || !line.hasPrefix("\t") && !line.hasPrefix(" ") {
                    inFailing = false
                } else if text.hasSuffix(":") {
                    bundle = String(text.dropLast())
                    continue
                } else if let test = Self.test(text, bundle: bundle) {
                    failingTests.append(test)
                    continue
                }
            }
            if text == "Failing tests:" {
                inFailing = true
                bundle = nil
                continue
            }
            if scheme == nil, text.contains("xcodebuild"), let value = Self.value(of: "-scheme", in: text) { scheme = value }
            if text.hasSuffix(".xcresult"), let path = text.split(separator: " ").last, path.hasPrefix("/") { resultBundle = String(path) }
            if projectDirectory == nil, let range = text.range(of: #"Git repository in (/.+)/\.git/?$"#, options: .regularExpression) {
                projectDirectory = text[range].replacingOccurrences(of: #"^Git repository in |/\.git/?$"#, with: "", options: .regularExpression)
            }
        }
    }

    /// `Suite.test()`, `Outer.Inner.test()`, in `bundle` when the list is grouped by target.
    static func test(_ text: String, bundle: String?) -> Test? {
        guard text.hasSuffix(")"), let open = text.firstIndex(of: "(") else { return nil }
        let parts = text[..<open].split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        return Test(bundle: bundle, suite: Array(parts.dropLast()), name: parts.last! + text[open...])
    }

    /// The word after `option` on a command line, unquoted.
    static func value(of option: String, in line: String) -> String? {
        let words = ShellWords.split(line)
        guard let i = words.firstIndex(of: option), i + 1 < words.count else { return nil }
        return words[i + 1]
    }

    /// The log without its terminal colours, GitLab's collapsible-section markers and carriage returns.
    static func plain(_ log: String) -> String {
        log.replacingOccurrences(of: #"\x{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"section_(start|end):[0-9]+:[A-Za-z0-9_.-]+(\[[^\]]*\])?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

/// A failing test of a CI job, from the pipeline's test report.
public struct CIFailure: Equatable, Sendable {
    /// The test target, when the report or the log names it.
    public var bundle: String?
    /// The suite's type path: `["CardTests"]`, `["AllSnapshots", "CardTests"]`.
    public var suite: [String]
    /// The test function, `testCard()` or `card()`.
    public var name: String
    public var message: String

    public init(bundle: String?, suite: [String], name: String, message: String) {
        self.bundle = bundle
        self.suite = suite
        self.name = name
        self.message = message
    }

    /// The test as `-only-testing:` names it within its bundle, `Suite/test()`.
    public var identifier: String { (suite + [name.hasSuffix(")") ? name : name + "()"]).joined(separator: "/") }

    /// A JUnit test case: its class names the suite, with the target in front when the writer put it there
    /// (`Bundle.Suite`), its name the test. The log's list of failing tests, grouped by target, tells the two
    /// apart; without it, a class of several parts is taken to start with its target, as xcodebuild's JUnit
    /// writers have it.
    public init(case testCase: CITestReport.Case, failingTests: [CITrace.Test]) {
        let parts = (testCase.classname ?? "").split(separator: ".").map(String.init)
        let name = testCase.name.hasSuffix(")") ? testCase.name : testCase.name + "()"
        if let listed = failingTests.first(where: { test in
            test.bundle != nil && test.name == name && (test.suite == parts || [test.bundle!] + test.suite == parts)
        }) {
            bundle = listed.bundle
            suite = listed.suite
        } else if parts.count > 1 {
            bundle = parts[0]
            suite = Array(parts.dropFirst())
        } else {
            bundle = nil
            suite = parts
        }
        self.name = name
        message = testCase.message
    }
}
