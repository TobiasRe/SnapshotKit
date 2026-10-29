import Foundation
import Testing
@testable import SnapshotKitCore

/// Open in SnapshotKit (the Services menu item) finds snapshots by the name in the selected text.
struct SnapshotLookupTests {
    @Test func takesTheNameFromWhatIsSelected() {
        #expect(SnapshotLookup.name(in: "payButton") == "payButton")
        #expect(SnapshotLookup.name(in: "  payButton()\n") == "payButton")
        #expect(SnapshotLookup.name(in: "@Test func payButton() {") == "payButton")
        #expect(SnapshotLookup.name(in: "func testPayButton() throws {") == "testPayButton")
        #expect(SnapshotLookup.name(in: "func sizes(width: Int) {") == "sizes")
        #expect(SnapshotLookup.name(in: "@Test func `pay button`() {") == "pay-button")
        #expect(SnapshotLookup.name(in: "@Suite struct CardTests {") == "CardTests")
        #expect(SnapshotLookup.name(in: "final class CardSnapshotTests: XCTestCase {") == "CardSnapshotTests")
        #expect(SnapshotLookup.name(in: " (){} ") == nil)
        #expect(SnapshotLookup.name(in: "") == nil)
    }

    @Test func findsATestsSnapshotsElseATestFiles() {
        let files = [
            "Tests/AppTests/__Snapshots__/CardTests/payButton.light.png",
            "Tests/AppTests/__Snapshots__/CardTests/payButton.dark.png",
            "Tests/AppTests/__Snapshots__/CardTests/payButtonLarge.1.png",
            "Tests/AppTests/__Snapshots__/CardTests/sizes-width.1.png",
            "Tests/AppTests/__Snapshots__/HeaderTests/title.1.png",
        ].map { SnapshotFile(path: $0, byteSize: 1) }
        let paths = { (name: String) in SnapshotLookup.snapshots(named: name, in: files).map(\.fileName) }
        #expect(paths("payButton") == ["payButton.light.png", "payButton.dark.png"])
        #expect(paths("sizes") == ["sizes-width.1.png"])
        #expect(paths("HeaderTests") == ["title.1.png"])
        #expect(paths("missing").isEmpty)
    }
}
