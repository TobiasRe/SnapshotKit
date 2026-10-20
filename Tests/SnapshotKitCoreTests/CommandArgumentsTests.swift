import Testing
@testable import SnapshotKitCore

@Suite struct CommandArgumentsTests {
    let options: [String: CommandArguments.Option] = ["--repo": .value, "--suite": .value, "--verbose": .flag, "--remote": .optionalValue]

    @Test func valuesFlagsAndRepeatedOptions() throws {
        let o = try CommandArguments(["--suite", "A/B", "--verbose", "--repo", "x", "--suite", "A/C", "--repo", "y"], options: options)
        #expect(o.all("--suite") == ["A/B", "A/C"])
        #expect(o.value("--repo") == "y")
        #expect(o.has("--verbose"))
        #expect(!o.has("--remote"))
    }

    @Test func optionalValues() throws {
        #expect(try CommandArguments(["--remote", "ci-mac"], options: options).value("--remote") == "ci-mac")
        let bare = try CommandArguments(["--remote", "--verbose"], options: options)
        #expect(bare.has("--remote") && bare.value("--remote") == nil && bare.has("--verbose"))
    }

    @Test func positionalArguments() throws {
        let o = try CommandArguments(["card", "--verbose", "dark"], options: options, positional: 0...Int.max)
        #expect(o.positional == ["card", "dark"])
        #expect(throws: UsageError("unexpected argument 'b'")) { try CommandArguments(["a", "b"], options: options, positional: 0...1) }
        #expect(throws: UsageError("missing arguments")) { try CommandArguments([], options: options, positional: 2...2) }
    }

    /// `--iterations 1` ran two iterations without a word; a flakiness check needs at least two.
    @Test func iterationsBelowAFlakinessCheckAreAnError() throws {
        let o = try CommandArguments(["--iterations", "1"], options: ["--iterations": .value])
        #expect(throws: UsageError("--iterations needs a whole number of at least 2, not '1'")) {
            try o.integer("--iterations", atLeast: Flakiness.minimumIterations)
        }
        #expect(Flakiness.arguments(iterations: 3).prefix(2) == ["-test-iterations", "3"])
    }

    @Test func rejectsUnknownOptionsAndMissingValues() {
        #expect(throws: UsageError("unknown option --verbse")) { try CommandArguments(["--verbse"], options: options) }
        #expect(throws: UsageError("--repo needs a value")) { try CommandArguments(["--repo"], options: options) }
        #expect(throws: UsageError("--repo needs a value")) { try CommandArguments(["--repo", "--verbose"], options: options) }
    }

    @Test func wholeNumbers() throws {
        let o = try CommandArguments(["--n", "3"], options: ["--n": .value, "--m": .value])
        #expect(try o.integer("--n", atLeast: 1) == 3)
        #expect(try o.integer("--m", atLeast: 1) == nil)
        #expect(throws: UsageError("--n needs a whole number of at least 4, not '3'")) { try o.integer("--n", atLeast: 4) }
        let text = try CommandArguments(["--n", "abc"], options: ["--n": .value])
        #expect(throws: UsageError.self) { try text.integer("--n", atLeast: 1) }
    }
}
