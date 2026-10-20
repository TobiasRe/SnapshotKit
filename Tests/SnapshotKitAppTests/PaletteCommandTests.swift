import SnapshotKitCore
import Testing
@testable import SnapshotKit

extension AppUITests {
    /// ⌘K offers what the open project can do now, named for what it will act on.
    @MainActor
    @Suite(.serialized)
    struct PaletteCommandTests {
        @Test func theSidebarsProjectActionsAreThereForTheKeyboard() {
            let app = AppModel(store: AppFixtures.store())
            let model = AppFixtures.project(.changes, store: app.store)
            app.show(model)
            var titles = PaletteCommand.available(app: app).map(\.title)
            #expect(titles.contains("Pin Project"))
            #expect(titles.contains("Reveal Project in Finder"))
            #expect(titles.contains("Remove Project from List"))

            app.togglePin(model.project)
            titles = PaletteCommand.available(app: app).map(\.title)
            #expect(titles.contains("Unpin Project") && !titles.contains("Pin Project"))
        }

        @Test func markingViewedSaysWhenAFilterLimitsIt() {
            let app = AppModel(store: AppFixtures.store())
            let model = AppFixtures.project(.changes, store: app.store)
            app.show(model)
            #expect(PaletteCommand.available(app: app).map(\.title).contains("Mark All Changes as Viewed"))

            model.changeFilter = "payButton"
            #expect(model.changesAreFiltered)
            #expect(PaletteCommand.available(app: app).map(\.title).contains("Mark All Shown Changes as Viewed"))

            model.setAllViewed(true)                                   // nothing left to mark
            #expect(!PaletteCommand.available(app: app).map(\.title).contains { $0.hasPrefix("Mark All") })
        }

        @Test func withoutXcodeNothingOffersToRunLocally() {
            let app = AppModel(store: AppFixtures.store())
            app.show(AppFixtures.project(.missingXcode, store: app.store))
            let titles = PaletteCommand.available(app: app).map(\.title)
            #expect(!titles.contains("Run Snapshot Tests"))
            #expect(!titles.contains("Re-record All Snapshot Tests…"))
        }
    }
}
