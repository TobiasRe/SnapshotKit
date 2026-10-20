import AppKit
import SnapshotKitCore
import SwiftUI
import Testing
@testable import SnapshotKit

extension AppUITests {
    /// A click on a list row has to reach the list, or the row can't be selected. Snapshot tests can't
    /// see this: a list can draw perfectly and still ignore clicks, as it did when a view behind each
    /// row (the one that turns off the system highlight) took every click.
    ///
    /// The tests ask the window which view a click in the middle of a row would go to. Synthetic mouse
    /// events don't select rows even in a plain SwiftUI List, so they can't be the check.
    @MainActor
    @Suite(.serialized)
    struct ListSelectionTests {
        init() {
            DS.solidSurfaces = true
            AppSnapshotTests.launchOnce()
        }

        @Test func clicksOnLibraryRowsReachTheList() throws {
            try expectClicksReachTheList(.library, tab: .snapshots)
        }

        @Test func clicksOnChangesReachTheList() throws {
            try expectClicksReachTheList(.changes, tab: .changes)
        }

        @Test func clicksOnFailuresReachTheList() throws {
            try expectClicksReachTheList(.failures, tab: .failures)
        }

        // MARK: Helpers

        private func expectClicksReachTheList(_ scenario: AppFixtures.Scenario, tab: ProjectTab,
                                              sourceLocation: SourceLocation = #_sourceLocation) throws {
            let store = AppFixtures.store()
            let app = AppModel(store: store)
            let project = AppFixtures.project(scenario, store: store)
            project.tab = tab
            app.show(project)
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1100, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ProjectView(project: project).environmentObject(app)
                .frame(width: 1100, height: 700))
            for _ in 0..<3 {
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            }

            let table = try #require(tables(in: window.contentView!).first { $0.numberOfRows > 2 }, "no list found",
                                     sourceLocation: sourceLocation)
            // Every visible row (not a section header), clicked in its middle.
            let rows = (0..<table.numberOfRows).filter { row in
                table.rect(ofRow: row).height > 30 && table.visibleRect.contains(table.rect(ofRow: row))
            }
            var checked = 0
            for row in rows {
                let chain = hitChain(in: window, at: table.rect(ofRow: row), of: table)
                guard !chain.contains(where: { $0.contains("Header") }) else { continue }
                checked += 1
                #expect(chain.contains("SwiftUIOutlineListView"), "row \(row): \(chain.prefix(4))", sourceLocation: sourceLocation)
                #expect(!chain.contains { $0.contains("NativeHighlightOff") || $0 == "Probe" },
                        "row \(row): a click lands on \(chain.prefix(3)), not on the list", sourceLocation: sourceLocation)
            }
            #expect(checked >= 2, "only \(checked) rows checked", sourceLocation: sourceLocation)
        }

        /// The view a click in the middle of `rect` goes to, and its superviews.
        private func hitChain(in window: NSWindow, at rect: NSRect, of table: NSTableView) -> [String] {
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            var chain: [String] = []
            var view = window.contentView?.hitTest(window.contentView!.convert(point, from: nil))
            while let current = view {
                chain.append(String(describing: type(of: current)))
                view = current.superview
            }
            return chain
        }

        private func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables(in:))
        }
    }
}
