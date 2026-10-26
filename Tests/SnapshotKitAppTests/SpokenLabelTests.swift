import SnapshotKitCore
import Testing
@testable import SnapshotKitUI

/// A row is one VoiceOver stop that says what a sighted user sees on it, in the same words.
struct SpokenLabelTests {
    let path = "Tests/AppTests/__Snapshots__/CheckoutViewTests/payButton.dark.png"

    @Test func aSnapshotSaysItsStateAndWhetherItFails() {
        let file = SnapshotFile(path: path, byteSize: 1, state: .modified)
        #expect(SnapshotStatusLine.spoken(file, SnapshotStatus(change: .uncommitted, failureID: "CheckoutViewTests/payButton()"))
                == "payButton dark, in CheckoutViewTests, Uncommitted, failing")
        #expect(SnapshotStatusLine.spoken(file, SnapshotStatus(failureID: "CheckoutViewTests/payButton()", verdict: .flaky))
                == "payButton dark, in CheckoutViewTests, Modified, flaky")
    }

    /// The line shows "Orphaned" whatever else is true; VoiceOver hears the same.
    @Test func anOrphanSaysSo() {
        let file = SnapshotFile(path: path, byteSize: 1)
        #expect(SnapshotStatusLine.spoken(file, SnapshotStatus(orphaned: true)) == "payButton dark, in CheckoutViewTests, Orphaned")
    }

    @Test func aCleanSnapshotIsJustItsName() {
        let file = SnapshotFile(path: "Tests/AppTests/__Snapshots__/CheckoutViewTests/payButton.png", byteSize: 1)
        #expect(SnapshotStatusLine.spoken(file, SnapshotStatus()) == "payButton, in CheckoutViewTests")
    }

    /// No stray space or comma where there is no variant.
    @Test func aChangeWithoutVariantReadsCleanly() {
        let change = SnapshotChange(path: path, kind: .committed)
        #expect(ChangeRow.spoken(change, variant: nil, viewed: false, diagnosis: nil) == "payButton, Committed, in CheckoutViewTests")
        #expect(ChangeRow.spoken(change, variant: "dark", viewed: true, diagnosis: nil)
                == "payButton dark, Committed, in CheckoutViewTests, viewed")
    }

    @Test func onlyNotableDiagnosesGetAWord() {
        #expect(DiagnosisChip.label(.imperceptible) == "Invisible")
        #expect(DiagnosisChip.label(.visible) == nil)
        #expect(DiagnosisChip.label(.identical) == nil)
    }

    @Test func aRunResultSaysItsOutcomeRunsAndTime() {
        let test = TestCaseResult(name: "payButton()", identifier: "CheckoutViewTests/payButton()", outcome: .failed,
                                  failureMessages: [], duration: 0.4, repetitions: [.passed, .failed, .failed])
        #expect(RunResultsList.spoken(test) == "payButton(), Failed, 1 of 3 runs passed, \(RunResultsList.duration(0.4))")
        let once = TestCaseResult(name: "summary()", identifier: "CheckoutViewTests/summary()", outcome: .passed,
                                  failureMessages: [], repetitions: [.passed])
        #expect(RunResultsList.spoken(once) == "summary(), Passed")
    }
}
