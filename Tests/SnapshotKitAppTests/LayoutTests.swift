import AppKit
import SwiftUI
import Testing
@testable import SnapshotKitUI

extension AppUITests {
    /// Layout that holds on any Mac: no pixels compared, so these run in CI too.
    @MainActor
    @Suite(.serialized)
    struct LayoutTests {
        init() {
            DS.solidSurfaces = true
            AppUITests.AppSnapshotTests.launchOnce()
            AppFixtures.resetDefaults()
        }

        /// Stepping through snapshots must not move the image: snapshots with and without variants,
        /// failing, changed, orphaned, with history loaded or still loading all start the canvas
        /// at the same height.
        @Test func canvasStaysPutBetweenSnapshots() {
            let store = AppFixtures.store()
            let app = AppModel(store: store)
            let project = AppFixtures.project(.library, store: store)
            app.show(project)
            final class Tops { var values: [String: CGFloat] = [:] }
            let tops = Tops()
            for file in project.displayedSnapshots {
                project.selectedSnapshotID = file.id
                let view = SnapshotDetail(project: project, file: file)
                    .environment(app)
                    .onPreferenceChange(SnapshotCanvasTopKey.self) { tops.values[file.testName + "." + file.variant] = $0 }
                // Narrow, as the detail pane often is: crowded headers must not grow either.
                AppFixtures.host(view, size: CGSize(width: 560, height: 600)) { _ in }
            }
            #expect(tops.values.count == project.displayedSnapshots.count)
            #expect(Set(tops.values.values).count == 1, "canvas tops differ: \(tops.values)")
        }
    }
}
