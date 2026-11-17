import Foundation
import SnapshotKitCore
import Testing
@testable import SnapshotKitUI

extension AppUITests {
    /// The keys without a modifier, and the list of shortcuts ? shows.
    @MainActor
    @Suite(.serialized)
    struct ShortcutTests {
        init() {
            AppFixtures.resetDefaults()
        }

        @Test func theSingleKeysAreTheOnesTyped() {
            #expect(SingleKey("j") == .next && SingleKey("k") == .previous)
            #expect(SingleKey("1") == .compare(.sideBySide) && SingleKey("2") == .compare(.slider))
            #expect(SingleKey("3") == .compare(.difference) && SingleKey("4") == .compare(.toggle))
            #expect(SingleKey("v") == .viewed && SingleKey("?") == .shortcuts)
            // Not with Shift (a capital), nor any other key or more than one.
            for other in ["J", "5", "0", " ", "", "jk", "/"] { #expect(SingleKey(other) == nil, "\(other)") }
            #expect(SingleKey.next.repeats && SingleKey.previous.repeats)
            #expect(!SingleKey.shortcuts.repeats && !SingleKey.viewed.repeats && !SingleKey.compare(.slider).repeats)
        }

        /// J and K step through the open section's list, and stop at its ends, as ⌥⌘↓ and ⌥⌘↑ do.
        /// Presses `key` as a view without a compare mode of its own would.
        func press(_ key: SingleKey, in app: AppModel) -> Bool {
            app.press(key, setCompareMode: { _ in })
        }

        @Test func jAndKStepThroughTheList() throws {
            let app = AppModel(store: AppFixtures.store())
            let project = AppFixtures.project(.changes, store: app.store)
            app.show(project)
            let shown = project.displayedChanges.map(\.id)
            try #require(shown.count > 1)
            project.selectedChangeID = shown[0]

            #expect(press(.next, in: app))
            #expect(project.selectedChangeID == shown[1])
            #expect(press(.previous, in: app))
            #expect(press(.previous, in: app))                    // at the top: stays there
            #expect(project.selectedChangeID == shown[0])

            // The Run view has no list to step through: the key goes on.
            project.section = .run
            #expect(!press(.next, in: app))
        }

        @Test func theNumbersPickTheCompareMode() {
            let app = AppModel(store: AppFixtures.store())
            var picked: [CompareMode] = []
            // Without a project there is nothing to compare.
            let withoutProject = app.press(.compare(.slider), setCompareMode: { picked.append($0) })
            #expect(!withoutProject && picked.isEmpty)
            app.show(AppFixtures.project(.changes, store: app.store))
            for mode in CompareMode.allCases {
                let handled = app.press(.compare(mode), setCompareMode: { picked.append($0) })
                #expect(handled)
            }
            #expect(picked == Array(CompareMode.allCases))
        }

        /// V on the image marks the selected change viewed, as V in the list does; elsewhere it is not a key.
        @Test func vMarksTheSelectedChangeViewed() throws {
            let app = AppModel(store: AppFixtures.store())
            let project = AppFixtures.project(.changes, store: app.store)
            app.show(project)
            let change = try #require(project.displayedChanges.first { !project.viewedChanges.contains($0.id) })
            project.selectedChangeID = change.id
            #expect(press(.viewed, in: app))
            #expect(project.viewedChanges.contains(change.id))

            project.section = .library
            #expect(!press(.viewed, in: app))
        }

        @Test func theQuestionMarkShowsAndHidesTheShortcuts() {
            let app = AppModel(store: AppFixtures.store())
            #expect(!app.showsShortcuts)
            #expect(press(.shortcuts, in: app))                     // also with no project open
            #expect(app.showsShortcuts)
            #expect(press(.shortcuts, in: app))
            #expect(!app.showsShortcuts)
            #expect(PaletteCommand.available(app: app).map(\.title).contains("Keyboard Shortcuts"))
            app.show(AppFixtures.project(.library, store: app.store))
            #expect(PaletteCommand.available(app: app).map(\.title).contains("Keyboard Shortcuts"))
        }

        /// Every line of the ? panel is in the documentation, by the same keys: as a row of their own, or,
        /// for a range ("⌥⌘1 – ⌥⌘6"), a row for each end.
        @Test func theDocumentationHasEveryShortcutListed() throws {
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let documentation = try String(contentsOf: repository.appendingPathComponent("docs/keyboard-shortcuts.md"), encoding: .utf8)
            func documented(_ keys: String) -> Bool {
                if documentation.contains("| \(keys) ") { return true }
                let ends = keys.components(separatedBy: " – ")
                return ends.count == 2 && ends.allSatisfy { documentation.contains("| \($0) ") }
            }
            let entries = ShortcutCatalog.groups.flatMap(\.entries)
            #expect(entries.count > 15)
            for entry in entries { #expect(documented(entry.keys), "\(entry.keys) (\(entry.action)) isn’t in docs/keyboard-shortcuts.md") }
            // No shortcut twice.
            #expect(Set(entries.map(\.keys)).count == entries.count)
        }
    }
}
