import SnapshotKitCore
import Testing
@testable import SnapshotKit

/// A snapshot's row says one thing about it, the most telling: that its test is gone, else how it
/// differs from the base branch, else that git hasn't committed it.
struct StatusLineTests {
    let path = "Tests/AppTests/__Snapshots__/CardTests/card.dark.png"

    @Test func anOrphanSaysSoWhateverElseIsTrue() {
        let file = SnapshotFile(path: path, byteSize: 1, state: .modified)
        #expect(SnapshotStatusLine.state(of: file, SnapshotStatus(change: .uncommitted, orphaned: true))?.label == "Orphaned")
    }

    @Test func aChangeAgainstTheBaseBranchBeatsTheWorkingTreeState() {
        // Re-recorded on a branch that already changed it: "Uncommitted" against the base, not "Modified".
        let file = SnapshotFile(path: path, byteSize: 1, state: .modified)
        #expect(SnapshotStatusLine.state(of: file, SnapshotStatus(change: .uncommitted))?.label == "Uncommitted")
        // "Committed" alone would read as unchanged; in the library a committed change is "Changed".
        #expect(SnapshotStatusLine.state(of: file, SnapshotStatus(change: .committed))?.label == "Changed")
    }

    @Test func withoutAChangeTheWorkingTreeStateShows() {
        #expect(SnapshotStatusLine.state(of: SnapshotFile(path: path, byteSize: 1, state: .untracked), SnapshotStatus())?.label == "New")
        #expect(SnapshotStatusLine.state(of: SnapshotFile(path: path, byteSize: 1, state: .modified), SnapshotStatus())?.label == "Modified")
    }

    @Test func aCleanSnapshotSaysNothing() {
        #expect(SnapshotStatusLine.state(of: SnapshotFile(path: path, byteSize: 1), SnapshotStatus()) == nil)
    }

    /// Failing is the row's mark on the right, never its status line.
    @Test func failingIsNotAState() {
        let status = SnapshotStatus(failureID: "CardTests/card()")
        #expect(SnapshotStatusLine.state(of: SnapshotFile(path: path, byteSize: 1), status) == nil)
    }
}
