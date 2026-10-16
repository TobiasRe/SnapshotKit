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

    @Test func missingTestFileIsAnError() throws {
        let repo = try repo()
        #expect(throws: RecordPatchError.self) {
            try RecordPlanner.plan([file("GoneTests", "x.1")], granularity: .tests, repository: repo.url)
        }
    }
}
