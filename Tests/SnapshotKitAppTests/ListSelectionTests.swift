import AppKit
import Combine
import OSLog
import SnapshotKitCore
import SwiftUI
import Testing
@testable import SnapshotKit

extension AppUITests {
    /// Selecting a row in a list has to work, and quietly. Snapshot tests can't see either: a list
    /// can draw perfectly and still ignore clicks, as it did when a view behind each row (one that
    /// turned off the system highlight) took every click. And a list that selects fine can still log
    /// "Publishing changes from within view updates" on every click, as it did while the models were
    /// `ObservableObject`s: on macOS 27 the list writes its selection binding from inside a view update.
    ///
    /// The click tests ask the window which view a click in the middle of a row would go to. Synthetic
    /// mouse events don't select rows even in a plain SwiftUI List, so they can't be the check. The
    /// selection tests select rows the way AppKit does after a click, and read the runtime issues
    /// SwiftUI logged meanwhile.
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

        @Test func selectingSnapshotsLogsNoRuntimeIssue() throws {
            try expectQuietSelection(.library, tab: .snapshots) { $0.selectedSnapshotID }
        }

        @Test func selectingChangesLogsNoRuntimeIssue() throws {
            try expectQuietSelection(.changes, tab: .changes) { $0.selectedChangeID }
        }

        @Test func selectingFailuresLogsNoRuntimeIssue() throws {
            try expectQuietSelection(.failures, tab: .failures) { $0.selectedFailureID }
        }

        /// The selection tests pass when nothing is logged, so first make sure a runtime issue would be
        /// seen: publishing from inside `body` is the classic way to cause one.
        @Test func runtimeIssuesAreSeen() throws {
            let since = Date()
            _ = host(PublishesWhileUpdating(model: Counter()))
            #expect(!(try runtimeIssues(since: since)).isEmpty, "a runtime issue was logged but not read back")
        }

        // MARK: Helpers

        private func expectClicksReachTheList(_ scenario: AppFixtures.Scenario, tab: ProjectTab,
                                              sourceLocation: SourceLocation = #_sourceLocation) throws {
            let (window, _) = hostProject(scenario, tab: tab)
            let table = try #require(tables(in: window.contentView!).first { $0.numberOfRows > 2 }, "no list found",
                                     sourceLocation: sourceLocation)
            var checked = 0
            for row in rows(of: table) {
                let chain = hitChain(in: window, at: table.rect(ofRow: row), of: table)
                guard !chain.contains(where: { $0.contains("Header") }) else { continue }
                checked += 1
                #expect(chain.contains("SwiftUIOutlineListView"), "row \(row): \(chain.prefix(4))", sourceLocation: sourceLocation)
                #expect(!chain.contains { $0 == "Probe" || $0.contains("Highlight") },
                        "row \(row): a click lands on \(chain.prefix(3)), not on the list", sourceLocation: sourceLocation)
            }
            #expect(checked >= 2, "only \(checked) rows checked", sourceLocation: sourceLocation)
        }

        private func expectQuietSelection(_ scenario: AppFixtures.Scenario, tab: ProjectTab,
                                          selection: (ProjectModel) -> String?,
                                          sourceLocation: SourceLocation = #_sourceLocation) throws {
            let (window, project) = hostProject(scenario, tab: tab)
            let table = try #require(tables(in: window.contentView!).first { $0.numberOfRows > 2 }, "no list found",
                                     sourceLocation: sourceLocation)
            let since = Date()
            var selected: Set<String> = []
            for row in rows(of: table).prefix(4) {
                // What NSTableView does after a click: select the row and post the selection change.
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                settle(window)
                if let id = selection(project) { selected.insert(id) }
            }
            #expect(selected.count >= 2, "selecting rows didn't change the selection", sourceLocation: sourceLocation)
            let issues = try runtimeIssues(since: since)
            #expect(issues.isEmpty, "\(issues.count) runtime issues, first: \(issues.first ?? "")", sourceLocation: sourceLocation)
        }

        private func hostProject(_ scenario: AppFixtures.Scenario, tab: ProjectTab) -> (NSWindow, ProjectModel) {
            let store = AppFixtures.store()
            let app = AppModel(store: store)
            let project = AppFixtures.project(scenario, store: store)
            project.tab = tab
            app.show(project)
            return (host(ProjectView(project: project).environment(app)), project)
        }

        private func host(_ view: some View) -> NSWindow {
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1100, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view.frame(width: 1100, height: 700))
            for _ in 0..<3 { settle(window) }
            return window
        }

        private func settle(_ window: NSWindow) {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }

        /// Every visible row, not a section header.
        private func rows(of table: NSTableView) -> [Int] {
            (0..<table.numberOfRows).filter { row in
                table.rect(ofRow: row).height > 30 && table.visibleRect.contains(table.rect(ofRow: row))
            }
        }

        /// What SwiftUI and AppKit reported to the runtime-issues log (Xcode's purple warnings).
        private func runtimeIssues(since date: Date) throws -> [String] {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            return try store.getEntries(at: store.position(date: date),
                                        matching: NSPredicate(format: "subsystem == %@", "com.apple.runtime-issues"))
                .map(\.composedMessage)
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

private final class Counter: ObservableObject {
    @Published var count = 0
}

private struct PublishesWhileUpdating: View {
    @ObservedObject var model: Counter
    var body: some View {
        if model.count == 0 { model.count = 1 }
        return Text("\(model.count)")
    }
}
