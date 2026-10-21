import AppKit
import SnapshotKitCore
import SnapshotTesting
import SwiftUI
import Testing
@testable import SnapshotKit

extension AppUITests {
    /// Snapshot tests of SnapshotKit's own UI, in light and dark appearance.
    ///
    /// Missing references are recorded automatically. To update all of them after an intended UI
    /// change: `SNAPSHOT_TESTING_RECORD=all swift test --filter AppSnapshotTests`.
    /// Glass is drawn as an opaque stand-in (`DS.solidSurfaces`) because off-screen rendering
    /// cannot composite Liquid Glass.
    @MainActor
    @Suite(.serialized)
    struct AppSnapshotTests {
        static let paneSize = CGSize(width: 1100, height: 700)
        /// 99.99% of pixels: tight enough that a changed word fails (the smallest wording change found
        /// moved 0.03% of a window; 99.9% let 16 stale references pass), with room for a stray
        /// antialiased edge.
        static let strategy = Snapshotting<NSView, NSImage>.image(precision: 0.9999, perceptualPrecision: 0.99)

        init() throws {
            DS.solidSurfaces = true
            AppModel.readsFailingCounts = false
            AppSnapshotTests.launchOnce()
            AppFixtures.resetDefaults()
            // On a 1x display every image would differ from its reference in size, which says nothing
            // about what changed.
            let scale = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true).backingScaleFactor
            try #require(scale == 2, "The references are drawn at 2x: run the snapshot tests on a Retina display (this one draws at \(scale)x).")
        }

        /// A launched (accessory, never activated) NSApplication renders split views, sidebars and
        /// toolbars the way the real app does; a bare test process leaves them blank.
        static var launched = false
        static func launchOnce() {
            guard !launched else { return }
            launched = true
            pinSystemSettings()
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.finishLaunching()
        }

        /// The references were drawn with System Settings' defaults: the Multicolor accent, which an app
        /// without an accent colour of its own draws in blue, and scroll bars shown only while scrolling
        /// (what Automatic is with a trackpad). Another accent would recolour the prominent buttons, the
        /// log's commands and focused selections; "Always" would add scroll bars. Pinned for this process
        /// only, in its argument domain, as `-AppleAccentColor 4` on its command line would, before
        /// AppKit reads them.
        private static func pinSystemSettings() {
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["AppleAccentColor"] = 4
            arguments["AppleShowScrollBars"] = "WhenScrolling"
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }

        // MARK: Project pane (everything below the toolbar)

        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func snapshotsTab(appearance: NSAppearance.Name) {
            let (app, project) = makeApp(.library)
            assertPane(project, app: app, appearance: appearance)
        }

        @Test func snapshotsGrid() {
            AppFixtures.defaults.set(LibraryLayout.grid.rawValue, forKey: "libraryLayout")
            let (app, project) = makeApp(.library)
            assertPane(project, app: app, appearance: .aqua)
        }

        @Test func snapshotsGridDark() {
            AppFixtures.defaults.set(LibraryLayout.grid.rawValue, forKey: "libraryLayout")
            let (app, project) = makeApp(.library)
            assertPane(project, app: app, appearance: .darkAqua)
        }

        /// A filter that matches nothing says so in the list; the selection stays in the detail.
        @Test func libraryFilterWithoutMatches() {
            let (app, project) = makeApp(.library)
            project.libraryFilter = "nothing like this"
            assertPane(project, app: app, appearance: .aqua)
        }

        /// The end of a review: every change viewed and viewed ones hidden.
        @Test func reviewFinished() {
            AppFixtures.defaults.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(.changes)
            project.setAllViewed(true)
            project.hideViewed = true
            project.selectedChangeID = nil
            assertPane(project, app: app, appearance: .aqua)
        }

        /// Comparing the current snapshot with the version from two months ago.
        @Test func snapshotComparedWithEarlierVersion() {
            AppFixtures.defaults.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(.library)
            let file = project.displayedSnapshots[0]
            let old = AppFixtures.snapshotVersions[2]
            let pair = ComparePair.make(before: project.versionLoader(for: file, commit: old.commit)(), after: project.snapshotLoader(for: file)())
            ComparePairCache.store(pair, for: file.cacheKey + "~" + old.commit)
            project.comparison = .version(old)
            assertPane(project, app: app, appearance: .aqua)
        }

        /// Light next to dark: two variants of the same test.
        @Test func snapshotComparedWithVariant() {
            AppFixtures.defaults.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(.library)
            let dark = project.displayedSnapshots[0], light = project.displayedSnapshots[1]
            ComparePairCache.store(ComparePair.make(before: project.snapshotLoader(for: light)(), after: project.snapshotLoader(for: dark)()),
                                   for: light.cacheKey + "~" + dark.cacheKey)
            project.comparison = .variant(light)
            assertPane(project, app: app, appearance: .aqua)
        }

        /// More variants than a segmented control holds: the info row picks them from a menu.
        @Test func snapshotWithManyVariants() {
            let (app, project) = makeApp(.manyVariants)
            #expect(project.variants(of: project.displayedSnapshots[0]).count == 6)
            assertPane(project, app: app, appearance: .aqua)
        }

        @Test func snapshotsBySize() {
            let (app, project) = makeApp(.library)
            project.librarySort = .size
            project.selectedSnapshotID = project.displayedSnapshots.first?.id
            #expect(project.displayedSnapshots.map(\.byteSize) == project.displayedSnapshots.map(\.byteSize).sorted(by: >))
            assertPane(project, app: app, appearance: .aqua)
        }

        @Test func orphanedSnapshots() {
            let (app, project) = makeApp(.library)
            project.libraryScope = .orphaned
            project.selectedSnapshotID = project.displayedSnapshots.first?.id
            assertPane(project, app: app, appearance: .aqua)
        }

        /// A snapshot whose test failed and that is new on this branch links to both views.
        @Test func snapshotWithFailureAndChange() {
            let (app, project) = makeApp(.library)
            project.libraryScope = .failing
            project.selectedSnapshotID = project.displayedSnapshots.first?.id
            assertPane(project, app: app, appearance: .aqua)
        }

        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func runTabAfterFailedRun(appearance: NSAppearance.Name) {
            let (app, project) = makeApp(.failedRun)
            assertPane(project, app: app, appearance: appearance)
        }

        @Test func runTabFilteredOutput() {
            let (app, project) = makeApp(.failedRun)
            project.runPane = .output
            project.logFilter = "payButton"
            assertPane(project, app: app, appearance: .aqua)
        }

        @Test func runTabWhileRunning() {
            let (app, project) = makeApp(.running)
            assertPane(project, app: app, appearance: .aqua)
        }

        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func changesTab(appearance: NSAppearance.Name) {
            AppFixtures.defaults.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(.changes)
            assertPane(project, app: app, appearance: appearance)
        }

        /// The outcome of the last run floats over another tab, with the way to its failures.
        @Test func noticeAfterAFailedRun() {
            AppFixtures.defaults.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(.failedRun)
            project.tab = .changes
            let view = ProjectView(project: project).environment(app)
            assertView(view, size: Self.paneSize, appearance: .aqua)
        }

        /// The narrowest pane the window allows (980 points less the sidebar): header buttons keep
        /// their labels and the titles beside them give way.
        @Test(arguments: [ProjectTab.changes, .run])
        func narrowPane(tab: ProjectTab) {
            AppFixtures.defaults.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(tab == .run ? .failedRun : .changes)
            project.tab = tab
            let view = ProjectView(project: project).environment(app)
            assertView(view, size: CGSize(width: 740, height: 520), appearance: .aqua, named: tab.rawValue.lowercased())
        }

        /// Increase Contrast: the selection, hairlines and labels must stay visible.
        @Test func changesTabWithIncreasedContrast() {
            AppFixtures.defaults.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(.changes)
            // The setting changes both: the appearance (system colors) and SwiftUI's contrast value, which
            // the glass controls read to draw their high-contrast stand-ins.
            let view = ProjectView(project: project).environment(app).environment(\._colorSchemeContrast, .increased)
            assertView(view, size: Self.paneSize, appearance: .accessibilityHighContrastAqua)
        }

        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func failuresTab(appearance: NSAppearance.Name) {
            AppFixtures.defaults.set(CompareMode.slider.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(.failures)
            assertPane(project, app: app, appearance: appearance)
        }

        // The label stays `name`: the reference files are named after it.
        @Test(arguments: [AppFixtures.Scenario.missingXcode, .brokenConfig, .missingBaseBranch, .neverRun])
        func problemStates(name scenario: AppFixtures.Scenario) {
            let (app, project) = makeApp(scenario)
            let view = ProjectView(project: project).environment(app)
            assertView(view, size: Self.paneSize, appearance: .aqua, named: "\(scenario)")
        }

        @Test func nothingChangedOrFailing() {
            let (app, project) = makeApp(.empty)
            project.tab = .changes
            assertPane(project, app: app, appearance: .aqua)
        }

        /// A project whose tests haven't recorded anything yet: one message, and the way to record.
        @Test func noSnapshotsYet() {
            let (app, project) = makeApp(.empty)
            project.tab = .snapshots
            assertPane(project, app: app, appearance: .aqua)
        }

        // MARK: Sidebar, quick switcher, welcome

        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func sidebar(appearance: NSAppearance.Name) {
            // No selection: the sidebar's selection material can't be rendered off-screen.
            let app = AppModel(store: AppFixtures.store())
            app.failingCounts = ["/work/payments-ui": 3, "/work/SampleApp": 2]
            let view = SidebarView().environment(app)
            assertView(view, size: CGSize(width: 260, height: 420), appearance: appearance,
                       named: appearance == .darkAqua ? "dark" : "light")
        }

        @Test func quickSwitcher() {
            let (app, _) = makeApp(.changes)
            QuickSwitcherQuery.preset = "pay"
            defer { QuickSwitcherQuery.preset = nil }
            let view = QuickSwitcherView().environment(app)
            assertView(view, size: CGSize(width: 700, height: 460), appearance: .aqua, keepFocus: true)
        }

        @Test func commandPalette() {
            let (app, _) = makeApp(.failedRun)
            QuickSwitcherQuery.preset = "rec"
            defer { QuickSwitcherQuery.preset = nil }
            let view = QuickSwitcherView().environment(app)
            assertView(view, size: CGSize(width: 700, height: 460), appearance: .aqua, keepFocus: true)
        }

        @Test func commandPaletteDark() {
            let (app, _) = makeApp(.failedRun)
            QuickSwitcherQuery.preset = ""
            defer { QuickSwitcherQuery.preset = nil }
            let view = QuickSwitcherView().environment(app)
            assertView(view, size: CGSize(width: 700, height: 520), appearance: .darkAqua, keepFocus: true)
        }

        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func settings(appearance: NSAppearance.Name) {
            let store = AppFixtures.store()
            store.addScanRoot("/work")
            store.addScanRoot("/Volumes/Projects/ios")
            let app = AppModel(store: store)
            let view = SettingsView().environment(app)
            assertView(view, size: CGSize(width: 520, height: 500), appearance: appearance,
                       named: appearance == .darkAqua ? "dark" : "light")
        }

        @Test func welcome() {
            let app = AppModel(store: AppFixtures.store())
            let view = WelcomeView().environment(app)
            assertView(view, size: CGSize(width: 700, height: 460), appearance: .aqua)
        }

        // MARK: Menu bar

        /// A run in progress (13 of 30 done) above recent projects with their failing counts.
        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func menuBarPanel(appearance: NSAppearance.Name) {
            let (app, project) = makeApp(.running)
            app.failingCounts = ["/work/payments-ui": 3]
            app.updateRunningPaths()
            #expect(app.runningPaths == [project.project.path])
            #expect(project.progressFraction.map { abs($0 - 13.0 / 30) < 0.001 } == true, "\(String(describing: project.progressFraction)) \(project.passed) \(project.failed) \(project.skipped)")
            let view = MenuBarPanel().environment(app)
            assertView(view, size: CGSize(width: MenuBarPanel.width, height: 380), appearance: appearance,
                       named: appearance == .darkAqua ? "dark" : "light")
        }

        /// Nothing running: the projects, the failing ones marked.
        @Test func menuBarPanelIdle() {
            let (app, _) = makeApp(.failedRun)
            app.failingCounts = ["/work/payments-ui": 3, "/work/SampleApp": 2]
            app.updateRunningPaths()
            let view = MenuBarPanel().environment(app)
            assertView(view, size: CGSize(width: MenuBarPanel.width, height: 380), appearance: .aqua)
        }

        /// The menu bar icon: unknown total, then 0, 40, 100 percent.
        @Test func progressPie() {
            let view = HStack(spacing: 12) {
                ForEach([nil, 0, 0.4, 1] as [Double?], id: \.self) { fraction in
                    Image(nsImage: ProgressPie.image(fraction: fraction))
                }
            }
            .padding(8)
            assertView(view, size: CGSize(width: 120, height: 32), appearance: .aqua)
        }

        // MARK: Compare view

        @Test(arguments: [CompareMode.sideBySide, .slider, .difference, .toggle])
        func compareModes(mode: CompareMode) {
            AppFixtures.defaults.set(mode.rawValue, forKey: "compareMode")
            let app = AppModel(store: AppFixtures.store())
            ComparePairCache.store(ComparePair.make(before: AppFixtures.reference, after: AppFixtures.actual), for: "compare-test")
            let view = CompareView(load: { (nil, nil) }, beforeLabel: "Reference", afterLabel: "Actual", identity: "compare-test")
                .environment(app)
            let name = switch mode { case .sideBySide: "side-by-side"; case .slider: "slider"; case .difference: "difference"; case .toggle: "toggle" }
            assertView(view, size: CGSize(width: 820, height: 480), appearance: .aqua, named: name)
        }

        /// A size change shows both sizes, the difference that matters.
        @Test func compareSizeChanged() {
            AppFixtures.defaults.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let app = AppModel(store: AppFixtures.store())
            let taller = AppFixtures.screen(accent: .systemBlue, height: 280)
            ComparePairCache.store(ComparePair.make(before: AppFixtures.reference, after: taller), for: "compare-size")
            let view = CompareView(load: { (nil, nil) }, beforeLabel: "Reference", afterLabel: "Actual", identity: "compare-size")
                .environment(app)
            assertView(view, size: CGSize(width: 820, height: 480), appearance: .aqua)
        }

        /// Several failures selected: the batch detail with its two actions.
        @Test func severalFailuresSelected() {
            let (app, project) = makeApp(.failures)
            project.selectFailures(Set(project.displayedFailures.map(\.id)))
            assertPane(project, app: app, appearance: .aqua)
        }

        /// A pair opened from outside (`snapkit open`, the diff tool): its own window, the header in the
        /// title bar beside the traffic lights.
        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func compareWindow(appearance: NSAppearance.Name) throws {
            AppFixtures.defaults.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let app = AppModel(store: AppFixtures.store())
            let dir = AppFixtures.temporaryDirectory("compare-window")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let reference = dir.appendingPathComponent("payButton.dark.png"), actual = dir.appendingPathComponent("actual.png")
            try AppFixtures.reference.write(to: reference)
            try AppFixtures.actual.write(to: actual)
            let request = CompareRequest(reference: reference, actual: actual)
            ComparePairCache.store(ComparePair.make(before: AppFixtures.reference, after: AppFixtures.actual),
                                   for: CompareWindow.identity(of: request))
            let view = CompareWindow(request: request,
                                     location: (URL(fileURLWithPath: "/work/payments-ui"),
                                                "Tests/AppSnapshotTests/__Snapshots__/CheckoutViewTests/payButton.dark.png"),
                                     leadingInset: 72)
                .environment(app)
            assertView(view, size: CGSize(width: 900, height: 560), appearance: appearance,
                       named: appearance == .darkAqua ? "dark" : "light")
        }

        /// The floating bar drops stats and size instead of wrapping.
        @Test func compareNarrowPane() {
            AppFixtures.defaults.set(CompareMode.difference.rawValue, forKey: "compareMode")
            let app = AppModel(store: AppFixtures.store())
            ComparePairCache.store(ComparePair.make(before: AppFixtures.reference, after: AppFixtures.actual), for: "compare-narrow")
            let view = CompareView(load: { (nil, nil) }, beforeLabel: "Reference", afterLabel: "Actual", identity: "compare-narrow")
                .environment(app)
            assertView(view, size: CGSize(width: 440, height: 360), appearance: .aqua, named: "440pt")
        }

        /// Rendering noise gets a note explaining it and the precision that would pass.
        @Test func compareImperceptibleDifference() {
            AppFixtures.defaults.set(CompareMode.difference.rawValue, forKey: "compareMode")
            let app = AppModel(store: AppFixtures.store())
            ComparePairCache.store(ComparePair.make(before: AppFixtures.reference, after: AppFixtures.renderingNoise), for: "compare-noise")
            let view = CompareView(load: { (nil, nil) }, beforeLabel: "Reference", afterLabel: "Actual", identity: "compare-noise")
                .environment(app)
            assertView(view, size: CGSize(width: 820, height: 480), appearance: .aqua)
        }

        /// ⇧⌘0 frames the changed pixels (here: only the button changed colour).
        @Test func compareZoomToChange() {
            AppFixtures.defaults.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let app = AppModel(store: AppFixtures.store())
            ComparePairCache.store(ComparePair.make(before: AppFixtures.reference, after: AppFixtures.badged), for: "compare-zoom-change")
            let view = CompareView(load: { (nil, nil) }, beforeLabel: "Reference", afterLabel: "Actual", identity: "compare-zoom-change")
                .environment(app)
            AppFixtures.host(view, size: CGSize(width: 820, height: 480)) { hosted in
                app.compare.zoomToChangeRequest += 1
                AppFixtures.settle(hosted)
                #expect(app.compare.viewport.scale > 2)
                assertSnapshot(of: hosted, as: Self.strategy)
            }
        }

        /// The readout shown while hovering: a pixel of the button that changed colour.
        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func pixelReadout(appearance: NSAppearance.Name) {
            let view = PixelReadout(probe: PixelProbe(x: 60, y: 175),
                                    before: PixelImage(data: AppFixtures.reference), after: PixelImage(data: AppFixtures.actual),
                                    beforeLabel: "Reference", afterLabel: "Actual")
                .padding()
            assertView(view, size: CGSize(width: 480, height: 64), appearance: appearance,
                       named: appearance == .darkAqua ? "dark" : "light")
        }

        /// Flaky pattern, then the same with Differentiate Without Color: failures hollow, mixed half filled.
        @Test(arguments: [false, true])
        func historyStrip(withoutColor: Bool) {
            let points = AppFixtures.timeline([.passed, .failed, .passed, .mixed, .failed, .passed])
            let view = HistoryStrip(points: points, size: .regular, differentiateWithoutColor: withoutColor)
                .padding()
            assertView(view, size: CGSize(width: 120, height: 48), appearance: .aqua, named: withoutColor ? "shapes" : "color")
        }

        @Test func compareZoomedIn() {
            AppFixtures.defaults.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let app = AppModel(store: AppFixtures.store())
            app.compare.viewport = Viewport(scale: 4, offset: CGSize(width: 120, height: -60))
            ComparePairCache.store(ComparePair.make(before: AppFixtures.reference, after: AppFixtures.actual), for: "compare-zoom")
            let view = CompareView(load: { (nil, nil) }, beforeLabel: "Reference", afterLabel: "Actual", identity: "compare-zoom")
                .environment(app)
            assertView(view, size: CGSize(width: 820, height: 480), appearance: .darkAqua, named: "dark-4x")
        }

        // MARK: Helpers

        private func makeApp(_ scenario: AppFixtures.Scenario) -> (AppModel, ProjectModel) {
            let store = AppFixtures.store()
            let app = AppModel(store: store)
            let project = AppFixtures.project(scenario, store: store)
            app.show(project)
            return (app, project)
        }

        private func assertPane(_ project: ProjectModel, app: AppModel, appearance: NSAppearance.Name,
                                fileID: StaticString = #fileID, file: StaticString = #filePath,
                                testName: String = #function, line: UInt = #line, column: UInt = #column) {
            assertView(ProjectView(project: project).environment(app), size: Self.paneSize, appearance: appearance,
                       named: appearance == .darkAqua ? "dark" : "light",
                       fileID: fileID, file: file, testName: testName, line: line, column: column)
        }

        private func assertView<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, keepFocus: Bool = false,
                                         named name: String? = nil,
                                         fileID: StaticString = #fileID, file: StaticString = #filePath,
                                         testName: String = #function, line: UInt = #line, column: UInt = #column) {
            AppFixtures.host(view, size: size, appearance: appearance, keepFocus: keepFocus) { hosted in
                assertSnapshot(of: hosted, as: Self.strategy, named: name,
                               fileID: fileID, file: file, testName: testName, line: line, column: column)
            }
        }
    }
}
