import Foundation

/// Coarse phases of an `xcodebuild test` run, for progress display.
public enum RunPhase: String, Codable, Sendable, Comparable {
    case preparing, resolvingPackages, building, testing, finished

    static let order: [RunPhase] = [.preparing, .resolvingPackages, .building, .testing, .finished]
    public static func < (a: RunPhase, b: RunPhase) -> Bool { order.firstIndex(of: a)! < order.firstIndex(of: b)! }

    public var label: String {
        switch self {
        case .preparing: "Preparing"
        case .resolvingPackages: "Resolving packages"
        case .building: "Building"
        case .testing: "Testing"
        case .finished: "Finished"
        }
    }
}

public enum TestEvent: Equatable, Sendable {
    case phase(RunPhase)
    case suiteStarted(String)
    case testStarted(String)
    case testPassed(String)
    case testFailed(String)
    case testSkipped(String)
    case buildError(String)
}

/// Incrementally interprets `xcodebuild test` output (Swift Testing and XCTest formats).
public struct TestOutputParser: Sendable {
    public private(set) var phase: RunPhase = .preparing
    public private(set) var passed = 0
    public private(set) var failed = 0
    public private(set) var skipped = 0
    public private(set) var failedTests: [String] = []
    public private(set) var buildErrors: [String] = []

    public init() {}

    public mutating func consume(_ rawLine: String) -> [TestEvent] {
        let line = String(Self.withoutInvisiblePrefix(rawLine))
        var events: [TestEvent] = []
        func setPhase(_ p: RunPhase) {
            // Phases only move forward (xcodebuild prints "Testing started" again at the very end).
            guard p > phase else { return }
            phase = p
            events.append(.phase(p))
        }

        if line.hasPrefix("Resolve Package Graph") || line.hasPrefix("Resolved source packages") || line.hasPrefix("Fetching from") {
            if phase == .preparing { setPhase(.resolvingPackages) }
        } else if phase == .preparing || phase == .resolvingPackages,
                  line.hasPrefix("CompileC ") || line.hasPrefix("SwiftCompile ") || line.hasPrefix("SwiftDriver") || line.hasPrefix("Ld ")
                    || line.hasPrefix("ComputePackagePrebuildTargetDependencyGraph") || line.hasPrefix("Prepare packages") {
            setPhase(.building)
        } else if line.hasPrefix("◇ Test run started") || line.hasPrefix("Testing started") || line.hasPrefix("Test Suite 'All tests' started")
                    || line.hasPrefix("Test Suite '") && line.contains("' started") {
            setPhase(.testing)
        } else if line.hasPrefix("** TEST SUCCEEDED **") || line.hasPrefix("** TEST FAILED **") || line.hasPrefix("** TEST INTERRUPTED **")
                    || line.hasPrefix("** BUILD FAILED **") || line.hasPrefix("** TEST EXECUTE") {
            setPhase(.finished)
        }

        if let error = Self.buildError(line) {
            buildErrors.append(error)
            events.append(.buildError(error))
        }

        // Swift Testing: "◇ Suite X started." / "✔ Test name() passed after …" / "✘ Test name() failed after …"
        // A parameterized test's cases start on lines of their own ("◇ Test case passing …"), and it
        // ends "✘ Test name(x:) with 2 test cases failed after …".
        if line.hasPrefix("◇ Suite "), let name = Self.between(line, "◇ Suite ", " started") {
            events.append(.suiteStarted(name))
        } else if line.hasPrefix("◇ Test "), !line.hasPrefix("◇ Test run"), !line.hasPrefix("◇ Test case "),
                  let name = Self.between(line, "◇ Test ", " started") {
            events.append(.testStarted(name))
        } else if line.hasPrefix("✔ Test "), !line.hasPrefix("✔ Test run"), let name = Self.between(line, "✔ Test ", " passed") {
            passed += 1
            events.append(.testPassed(Self.withoutCaseCount(name)))
        } else if line.hasPrefix("✘ Test "), !line.hasPrefix("✘ Test run"), line.contains(" failed after"),
                  let name = Self.between(line, "✘ Test ", " failed").map(Self.withoutCaseCount) {
            failed += 1
            failedTests.append(name)
            events.append(.testFailed(name))
        } else if line.hasPrefix("➜ Test ") && line.contains(" skipped"), let name = Self.between(line, "➜ Test ", " skipped") {
            skipped += 1
            events.append(.testSkipped(Self.withoutCaseCount(name)))
        } else if line.hasPrefix("Test Case '") || line.hasPrefix("Test case '") {
            // XCTest: "Test Case '-[Mod.Suite testX]' passed (0.1 seconds)." or
            //         "Test case 'Suite.testX()' failed on 'Clone 1 of …' (0.1 seconds)"
            guard let open = line.firstIndex(of: "'"),
                  let close = line[line.index(after: open)...].range(of: "' ") else { return events }
            let name = String(line[line.index(after: open)..<close.lowerBound])
            let rest = line[close.upperBound...]
            if rest.hasPrefix("passed") {
                passed += 1
                events.append(.testPassed(name))
            } else if rest.hasPrefix("failed") {
                failed += 1
                failedTests.append(name)
                events.append(.testFailed(name))
            } else if rest.hasPrefix("skipped") {
                skipped += 1
                events.append(.testSkipped(name))
            } else if rest.hasPrefix("started") {
                events.append(.testStarted(name))
            }
        }
        return events
    }

    /// The line without the zero-width spaces (and other invisible format characters) Swift Testing
    /// can leave at its start, as after an issue's message: "\u{200B}\u{200B}✘ Test …".
    public static func withoutInvisiblePrefix(_ line: String) -> Substring {
        line.drop { $0.unicodeScalars.allSatisfy { $0.properties.generalCategory == .format } }
    }

    /// "named(name:) with 2 test cases" → "named(name:)".
    static func withoutCaseCount(_ name: String) -> String {
        guard let range = name.range(of: #" with \d+ test cases?$"#, options: .regularExpression) else { return name }
        return String(name[..<range.lowerBound])
    }

    static func buildError(_ line: String) -> String? {
        guard !line.hasPrefix("✘"), let range = line.range(of: ": error: ") else { return nil }
        let location = line[..<range.lowerBound].split(separator: "/").last.map(String.init) ?? ""
        return location.isEmpty ? String(line[range.upperBound...]) : "\(location): \(line[range.upperBound...])"
    }

    static func between(_ line: String, _ start: String, _ end: String) -> String? {
        guard let s = line.range(of: start) else { return nil }
        guard let e = line.range(of: end, range: s.upperBound..<line.endIndex) else { return nil }
        let value = String(line[s.upperBound..<e.lowerBound])
        return value.isEmpty ? nil : value
    }
}
