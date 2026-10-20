import SwiftUI
import Testing
@testable import SnapshotKit

/// Messages name commands in backticks; a note sets them in code type and leaves the rest alone.
struct StatusNoteTests {
    @Test func commandsInBackticksAreSetInCodeType() {
        let text = StatusNote.code("Xcode 99.2 isn’t installed. Run `xcodes install 99.2`, then check again.")
        #expect(String(text.characters) == "Xcode 99.2 isn’t installed. Run xcodes install 99.2, then check again.")
        let code = text.runs.filter { $0.font == DS.Font.code }.map { String(text[$0.range].characters) }
        #expect(code == ["xcodes install 99.2"])
    }

    /// A heading or notice sets its code in its own size, not a note's caption.
    @Test func largerTextSetsCodeInItsOwnSize() {
        let font = DS.Font.heading.monospaced()
        let text = StatusNote.code("Set `remoteHost:` first.", font: font)
        #expect(text.runs.compactMap(\.font) == [font])
    }

    @Test func aStrayBacktickStaysAsTyped() {
        #expect(String(StatusNote.code("It's `odd").characters) == "It's `odd")
    }

    /// Only backticks: Markdown would make `__Snapshots__` in a path bold.
    @Test func underscoresInPathsStayPlain() {
        let path = "Tests/AppTests/__Snapshots__/CardTests/card.png is missing."
        let text = StatusNote.code(path)
        #expect(String(text.characters) == path)
        #expect(text.runs.allSatisfy { $0.font == nil })
    }
}
