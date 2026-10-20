import Foundation
import Testing
@testable import SnapshotKitCore

@Suite struct RecordPlannerTests {
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

    @Test func missingTestFileIsAnError() throws {
        let repo = try repo()
        #expect(throws: RecordPatchError.self) {
            try RecordPlanner.plan([file("GoneTests", "x.1")], granularity: .tests, repository: repo.url)
        }
    }
}
