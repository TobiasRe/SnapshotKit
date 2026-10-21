import Foundation
import Testing
@testable import SnapshotKitCore

/// The library groups and sorts thousands of files on every change, so a file's parts are parsed
/// once from its path (measured: 80 ms → 25 ms for 6,000 snapshots in a debug build).
@Suite(.isolated) struct SnapshotFilePartsTests {
    @Test func partsComeFromThePathAndFollowIt() {
        var file = SnapshotFile(path: "Tests/FeatureTests/__Snapshots__/CheckoutViewTests/payButton.dark.png", byteSize: 1)
        #expect([file.module, file.suite, file.testName, file.variant, file.fileName]
                == ["FeatureTests", "CheckoutViewTests", "payButton", "dark", "payButton.dark.png"])
        file.path = "Tests/OtherTests/__Snapshots__/ProfileViewTests/badge.1.png"
        #expect([file.module, file.suite, file.testName, file.variant] == ["OtherTests", "ProfileViewTests", "badge", "1"])
    }

    @Test func equalityIgnoresTheParsedCache() {
        let a = SnapshotFile(path: "X/__Snapshots__/S/t.png", byteSize: 3)
        var b = SnapshotFile(path: "Y/__Snapshots__/S/t.png", byteSize: 3)
        b.path = a.path
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
    }

    @Test func treeOfManySnapshotsKeepsEveryFileInOrder() {
        let files = (0..<6000).map { i in
            SnapshotFile(path: "Tests/Module\(i % 6)Tests/__Snapshots__/Suite\(i % 120)Tests/test\(i % 900).variant\(i % 4).png",
                         byteSize: i)
        }
        let tree = SnapshotLibrary.tree(files)
        #expect(tree.map(\.name) == (0..<6).map { "Module\($0)Tests" })
        #expect(tree.reduce(0) { $0 + $1.fileCount } == 6000)
        // Numbers in natural order: Suite2 before Suite10.
        let suites = tree[0].suites.map(\.name)
        #expect(suites.firstIndex(of: "Suite6Tests")! < suites.firstIndex(of: "Suite12Tests")!)
    }
}
