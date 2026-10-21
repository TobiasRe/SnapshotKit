import Foundation
import Testing
@testable import SnapshotKitCore

@Suite(.isolated) struct RecordPlannerTests {
    func repo() throws -> TempRepo {
        let repo = try TempRepo()
        try repo.write("Tests/AppTests/CardTests.swift", """
            import SnapshotTesting
            import Testing

            @Suite struct CardTests {
                @Test func compact() {}
                @Test func expanded() {}
                @Test(arguments: [1, 2]) func sized(width: Int) {}
            }
            """)
        try repo.write("Tests/AppTests/LegacyTests.swift", """
            import SnapshotTesting
            import XCTest

            final class LegacyTests: XCTestCase {
                func testHeader() {}
            }
            """)
        try repo.write("Tests/AppTests/NestedTests.swift", """
            import Testing

            extension AllUITests {
                @Suite struct NestedTests {
                    @Test func row() {}
                }
            }
            """)
        try repo.commitAll("tests")
        return repo
    }

    func file(_ suite: String, _ name: String) -> SnapshotFile {
        SnapshotFile(path: "Tests/AppTests/__Snapshots__/\(suite)/\(name).png", byteSize: 1)
    }

    @Test func singleTestsInSwiftTestingXCTestAndNestedSuites() throws {
        let repo = try repo()
        let plan = try RecordPlanner.plan([file("CardTests", "compact.1"), file("CardTests", "compact.dark"),
                                           file("LegacyTests", "testHeader.1"), file("NestedTests", "row.1")],
                                          granularity: .tests, repository: repo.url)
        #expect(plan.onlyTesting == ["AppTests/CardTests/compact()", "AppTests/LegacyTests/testHeader", "AppTests/AllUITests/NestedTests/row()"])
        #expect(plan.suites.map(\.identifier) == ["AppTests/CardTests", "AppTests/LegacyTests", "AppTests/AllUITests/NestedTests"])
        #expect(plan.suites[0].failureFiles.first?.hasSuffix("Tests/AppTests/CardTests.swift") == true)
    }

    /// A suite type named with a raw identifier is named with its backticks, as `-only-testing` takes it.
    @Test func aSuiteWithARawIdentifier() throws {
        let repo = try TempRepo()
        let source = "import Testing\n\n@Suite struct `Card views` {\n    @Test func card() {}\n}\n"
        try repo.write("Tests/AppTests/CardTests.swift", source)
        try repo.commitAll("tests")
        let plan = try RecordPlanner.plan([file("CardTests", "card.1")], granularity: .tests, repository: repo.url)
        #expect(plan.onlyTesting == ["AppTests/`Card views`/card()"])
        #expect(plan.suites.map(\.path) == [["`Card views`"]])
        #expect(try SuiteLocator.targets(for: plan.suites, in: repo.url).map(\.path) == ["Tests/AppTests/CardTests.swift"])
        #expect(try RecordPatcher.patch(source: source, suite: ["`Card views`"])
                == "import Testing\n\n@Suite(.snapshots(record: .all)) struct `Card views` {\n    @Test func card() {}\n}\n")
    }

    @Test func parameterizedTestsAndSuiteGranularityRunTheSuite() throws {
        let repo = try repo()
        let parameterized = try RecordPlanner.plan([file("CardTests", "sized-width.1"), file("CardTests", "compact.1")],
                                                   granularity: .tests, repository: repo.url)
        #expect(parameterized.onlyTesting == ["AppTests/CardTests"])
        let suites = try RecordPlanner.plan([file("CardTests", "expanded.1")], granularity: .suites, repository: repo.url)
        #expect(suites.onlyTesting == ["AppTests/CardTests"])
    }

    /// Thousands of snapshots live in a few test files: each is read once, not once per snapshot
    /// (re-recording 3,000 snapshots took 3 seconds before anything ran).
    @Test func readsEachTestFileOnce() throws {
        let repo = try repo()
        let files = (1...200).flatMap { n in [file("CardTests", "compact.\(n)"), file("CardTests", "expanded.\(n)"), file("LegacyTests", "testHeader.\(n)")] }
        let sources = TestSources(repository: repo.url)
        let selection = try RecordPlanner.plan(files, granularity: .tests, sources: sources)
        #expect(selection.onlyTesting == ["AppTests/CardTests/compact()", "AppTests/CardTests/expanded()", "AppTests/LegacyTests/testHeader"])
        #expect(sources.reads == 2)

        let orphanSources = TestSources(repository: repo.url)
        #expect(SnapshotLibrary.orphans(files + [file("CardTests", "gone.1")], sources: orphanSources) == ["Tests/AppTests/__Snapshots__/CardTests/gone.1.png"])
        #expect(orphanSources.reads == 2)
    }

    /// swift-snapshot-testing names the folder after the file, so a test in a suite nested in the
    /// file's suite looks like one of the outer suite's. `-only-testing:AppTests/CardTests/badge()`
    /// would run nothing; the outer suite runs it. A comment naming the test is no declaration.
    @Test func aTestInANestedSuiteRunsTheOuterSuite() throws {
        let repo = try TempRepo()
        try repo.write("Tests/AppTests/CardTests.swift", """
            import Testing

            @Suite struct CardTests {
                @Suite struct Dark {
                    @Test func badge() {}
                }
                @Test func plain() {}
                // func badge() is in Dark
            }

            extension CardTests {
                @Test func extra() {}
            }
            """)
        try repo.commitAll("tests")
        func only(_ names: String...) throws -> [String] {
            try RecordPlanner.plan(names.map { file("CardTests", $0) }, granularity: .tests, repository: repo.url).onlyTesting
        }
        #expect(try only("plain.1") == ["AppTests/CardTests/plain()"])
        #expect(try only("badge.1") == ["AppTests/CardTests"])
        #expect(try only("extra.1") == ["AppTests/CardTests/extra()"])  // an extension's tests are the suite's
        #expect(try only("plain.1", "badge.1") == ["AppTests/CardTests"])
    }

    /// `@Test` functions outside a type are their target's own: each runs by its identifier (a
    /// parameterized one too, its snapshot name being the sanitized identifier), as the target's
    /// identifier alone would run every test in it.
    @Test func testsOutsideATypeRunOneByOne() throws {
        let repo = try TempRepo()
        try repo.write("Tests/AppTests/CardSnapshots.swift", """
            import Testing

            @Test func compact() {}
            @Test(arguments: [1, 2]) func sized(width: Int) {}
            """)
        try repo.write("Tests/AppTests/RowSnapshots.swift", "import Testing\n\n@Test func row() {}\n")
        try repo.commitAll("tests")
        let tests = try RecordPlanner.plan([file("CardSnapshots", "sized-width.1"), file("RowSnapshots", "row.1")],
                                           granularity: .tests, repository: repo.url)
        #expect(tests.onlyTesting == ["AppTests/sized(width:)", "AppTests/row()"])
        #expect(tests.suites.map(\.identifier) == ["AppTests"])
        #expect(tests.suites.first?.path == [])
        #expect(tests.suites.first?.failureFiles.map { ($0 as NSString).lastPathComponent } == ["CardSnapshots.swift", "RowSnapshots.swift"])
        // A whole "suite": every test of the file outside a type.
        let file = try RecordPlanner.plan([file("CardSnapshots", "compact.1")], granularity: .suites, repository: repo.url)
        #expect(file.onlyTesting == ["AppTests/compact()", "AppTests/sized(width:)"])
        #expect(try SuiteLocator.targets(for: tests.suites, in: repo.url).map(\.path) == ["Tests/AppTests/CardSnapshots.swift", "Tests/AppTests/RowSnapshots.swift"])
    }

    /// A raw identifier, `` `pay button`() ``, whose snapshots are "pay-button", is a test like any
    /// other: it, not the file's other tests, is recorded (by the identifier Xcode reports).
    @Test func aTestOutsideATypeWithARawIdentifier() throws {
        let repo = try TempRepo()
        try repo.write("Tests/AppTests/CardSnapshots.swift", "import Testing\n\n@Test func compact() {}\n@Test func `pay button`() {}\n")
        try repo.commitAll("tests")
        #expect(RecordPatcher.topLevelTests(in: try repo.read("Tests/AppTests/CardSnapshots.swift")).map(\.identifier)
                == ["compact()", "`pay button`()"])
        let selection = try RecordPlanner.plan([file("CardSnapshots", "pay-button.1")], granularity: .tests, repository: repo.url)
        #expect(selection.onlyTesting == ["AppTests/`pay button`()"])
    }

    @Test func missingTestFileIsAnError() throws {
        let repo = try repo()
        #expect(throws: RecordPatchError.self) {
            try RecordPlanner.plan([file("GoneTests", "x.1")], granularity: .tests, repository: repo.url)
        }
    }
}
