import Foundation
import Testing
@testable import SnapshotKitCore

@Suite(.isolated) struct TestSourceLocatorTests {
    @Test func findsTheFileAndTheTestFunction() throws {
        let repo = try TempRepo()
        try repo.write("Tests/AppTests/CardTests.swift", Data("""
        import Testing

        struct CardTests {
            @Test func payButton() {}

            @Test(arguments: [1, 2])
            func sizes(width: Int) {}
        }
        """.utf8))
        try repo.write("Tests/AppTests/__Snapshots__/CardTests/payButton.dark.png", Data([0]))
        try repo.commitAll("tests")
        let pay = SnapshotFile(path: "Tests/AppTests/__Snapshots__/CardTests/payButton.dark.png", byteSize: 1)
        #expect(TestSourceLocator.locate(pay, in: repo.url) == TestSourceLocation(path: "Tests/AppTests/CardTests.swift", line: 4))
        let sized = SnapshotFile(path: "Tests/AppTests/__Snapshots__/CardTests/sizes-width.1.png", byteSize: 1)
        #expect(TestSourceLocator.locate(sized, in: repo.url)?.line == 7)
        let gone = SnapshotFile(path: "Tests/AppTests/__Snapshots__/OldTests/x.1.png", byteSize: 1)
        #expect(TestSourceLocator.locate(gone, in: repo.url) == nil)
    }
}
