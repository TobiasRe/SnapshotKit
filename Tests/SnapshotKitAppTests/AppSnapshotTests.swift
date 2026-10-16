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
        static let strategy = Snapshotting<NSView, NSImage>.image(precision: 0.999, perceptualPrecision: 0.99)

        init() {
            DS.solidSurfaces = true
            AppSnapshotTests.launchOnce()
        }

        /// A launched (accessory, never activated) NSApplication renders split views, sidebars and
        /// toolbars the way the real app does; a bare test process leaves them blank.
        static var launched = false
        static func launchOnce() {
            guard !launched else { return }
            launched = true
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.finishLaunching()
        }

        // MARK: Project pane (everything below the toolbar)

        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func snapshotsTab(appearance: NSAppearance.Name) {
            let (app, project) = makeApp(.library)
            assertPane(project, app: app, appearance: appearance)
        }

        @Test func snapshotsGrid() {
            UserDefaults.standard.set(LibraryLayout.grid.rawValue, forKey: "libraryLayout")
            defer { UserDefaults.standard.set(LibraryLayout.list.rawValue, forKey: "libraryLayout") }
            let (app, project) = makeApp(.library)
            assertPane(project, app: app, appearance: .aqua)
        }

        /// Comparing the current snapshot with the version from two months ago.
        @Test func snapshotComparedWithEarlierVersion() {
            UserDefaults.standard.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(.library)
            let file = project.displayedSnapshots[0]
            let old = AppFixtures.snapshotVersions[2]
            let pair = ComparePair.make(before: project.versionLoader(for: file, commit: old.commit)(), after: project.snapshotLoader(for: file)())
            ComparePairCache.store(pair, for: "\(file.path)#\(file.byteSize)@\(old.commit)")
            project.comparison = .version(old)
            assertPane(project, app: app, appearance: .aqua)
        }

        /// Light next to dark: two variants of the same test.
        @Test func snapshotComparedWithVariant() {
            UserDefaults.standard.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(.library)
            let dark = project.displayedSnapshots[0], light = project.displayedSnapshots[1]
            ComparePairCache.store(ComparePair.make(before: project.snapshotLoader(for: light)(), after: project.snapshotLoader(for: dark)()),
                                   for: "\(light.path)#\(light.byteSize)~\(dark.path)#\(dark.byteSize)")
            project.comparison = .variant(light)
            assertPane(project, app: app, appearance: .aqua)
        }

        @Test func snapshotsBySize() {
            let (app, project) = makeApp(.library)
            project.librarySort = .size
            defer { project.librarySort = .name }
            project.selectedSnapshotID = project.displayedSnapshots.first?.id
            #expect(project.displayedSnapshots.map(\.byteSize) == project.displayedSnapshots.map(\.byteSize).sorted(by: >))
            assertPane(project, app: app, appearance: .aqua)
        }

        /// Stepping through snapshots must not move the image: snapshots with and without variants,
        /// failing, changed, orphaned, with history loaded or still loading all start the canvas
        /// at the same height.
        @Test func canvasStaysPutBetweenSnapshots() {
            let (app, project) = makeApp(.library)
            final class Tops { var values: [String: CGFloat] = [:] }
            let tops = Tops()
            for file in project.displayedSnapshots {
                project.selectedSnapshotID = file.id
                let view = SnapshotDetail(project: project, file: file)
                    .environmentObject(app)
                    .onPreferenceChange(SnapshotCanvasTopKey.self) { tops.values[file.testName + "." + file.variant] = $0 }
                // Narrow, as the detail pane often is: crowded headers must not grow either.
                _ = host(view, size: CGSize(width: 560, height: 600), appearance: .aqua)
            }
            #expect(tops.values.count == project.displayedSnapshots.count)
            #expect(Set(tops.values.values).count == 1, "canvas tops differ: \(tops.values)")
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
            UserDefaults.standard.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(.changes)
            assertPane(project, app: app, appearance: appearance)
        }

        /// The outcome of the last run floats under the bars of another tab, without moving them.
        @Test func noticeAfterAFailedRun() {
            UserDefaults.standard.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(.failedRun)
            project.tab = .failures
            let view = ProjectView(project: project).environmentObject(app)
            assertSnapshot(of: host(view, size: Self.paneSize, appearance: .aqua), as: Self.strategy)
        }

        /// Increase Contrast: the selection, hairlines and labels must stay visible.
        @Test func changesTabWithIncreasedContrast() {
            UserDefaults.standard.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(.changes)
            let view = ProjectView(project: project).environmentObject(app)
            assertSnapshot(of: host(view, size: Self.paneSize, appearance: .accessibilityHighContrastAqua), as: Self.strategy)
        }

        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func failuresTab(appearance: NSAppearance.Name) {
            UserDefaults.standard.set(CompareMode.slider.rawValue, forKey: "compareMode")
            let (app, project) = makeApp(.failures)
            assertPane(project, app: app, appearance: appearance)
        }

        @Test(arguments: ["missingXcode", "brokenConfig", "missingBaseBranch", "neverRun"])
        func problemStates(name: String) {
            let scenario: AppFixtures.Scenario = switch name {
            case "missingXcode": .missingXcode
            case "brokenConfig": .brokenConfig
            case "missingBaseBranch": .missingBaseBranch
            default: .neverRun
            }
            let (app, project) = makeApp(scenario)
            let view = ProjectView(project: project).environmentObject(app)
            assertSnapshot(of: host(view, size: Self.paneSize, appearance: .aqua), as: Self.strategy, named: name)
        }

        @Test func nothingChangedOrFailing() {
            let (app, project) = makeApp(.empty)
            project.tab = .changes
            assertPane(project, app: app, appearance: .aqua)
        }

        // MARK: Sidebar, quick switcher, welcome

        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func sidebar(appearance: NSAppearance.Name) {
            // No selection: the sidebar's selection material can't be rendered off-screen.
            let app = AppModel(store: AppFixtures.store())
            app.failingCounts = ["/work/payments-ui": 3, "/work/SampleApp": 2]
            let view = SidebarView().environmentObject(app)
            assertSnapshot(of: host(view, size: CGSize(width: 260, height: 420), appearance: appearance), as: Self.strategy,
                           named: appearance == .darkAqua ? "dark" : "light")
        }

        @Test func quickSwitcher() {
            let (app, _) = makeApp(.changes)
            QuickSwitcherQuery.preset = "pay"
            defer { QuickSwitcherQuery.preset = nil }
            let view = QuickSwitcherView().environmentObject(app)
            assertSnapshot(of: host(view, size: CGSize(width: 700, height: 460), appearance: .aqua), as: Self.strategy)
        }

        @Test func commandPalette() {
            let (app, _) = makeApp(.failedRun)
            QuickSwitcherQuery.preset = "rec"
            defer { QuickSwitcherQuery.preset = nil }
            let view = QuickSwitcherView().environmentObject(app)
            assertSnapshot(of: host(view, size: CGSize(width: 700, height: 460), appearance: .aqua), as: Self.strategy)
        }

        @Test func settings() {
            let store = AppFixtures.store()
            store.addScanRoot("/work")
            store.addScanRoot("/Volumes/Projects/ios")
            let app = AppModel(store: store)
            let view = SettingsView().environmentObject(app)
            assertSnapshot(of: host(view, size: CGSize(width: 520, height: 500), appearance: .aqua), as: Self.strategy)
        }

        @Test func welcome() {
            let app = AppModel(store: AppFixtures.store())
            let view = WelcomeView().environmentObject(app)
            assertSnapshot(of: host(view, size: CGSize(width: 700, height: 460), appearance: .aqua), as: Self.strategy)
        }

        // MARK: Menu bar

        /// A run in progress (12 of 30 done) above recent projects with their failing counts.
        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func menuBarPanel(appearance: NSAppearance.Name) {
            let (app, project) = makeApp(.running)
            app.failingCounts = ["/work/payments-ui": 3]
            app.updateRunningPaths()
            #expect(app.runningPaths == [project.project.path])
            #expect(project.progressFraction.map { abs($0 - 13.0 / 30) < 0.001 } == true, "\(String(describing: project.progressFraction)) \(project.passed) \(project.failed) \(project.skipped)")
            let view = MenuBarPanel().environmentObject(app)
            assertSnapshot(of: host(view, size: CGSize(width: MenuBarPanel.width, height: 380), appearance: appearance), as: Self.strategy,
                           named: appearance == .darkAqua ? "dark" : "light")
        }

        /// The menu bar icon: unknown total, then 0, 40, 100 percent.
        @Test func progressPie() {
            let view = HStack(spacing: 12) {
                ForEach([nil, 0, 0.4, 1] as [Double?], id: \.self) { fraction in
                    Image(nsImage: ProgressPie.image(fraction: fraction))
                }
            }
            .padding(8)
            assertSnapshot(of: host(view, size: CGSize(width: 120, height: 32), appearance: .aqua), as: Self.strategy)
        }

        // MARK: Compare view

        @Test(arguments: [CompareMode.sideBySide, .slider, .difference, .toggle])
        func compareModes(mode: CompareMode) {
            UserDefaults.standard.set(mode.rawValue, forKey: "compareMode")
            let app = AppModel(store: AppFixtures.store())
            ComparePairCache.store(ComparePair.make(before: AppFixtures.reference, after: AppFixtures.actual), for: "compare-test")
            let view = CompareView(load: { (nil, nil) }, beforeLabel: "Reference", afterLabel: "Actual", identity: "compare-test")
                .environmentObject(app)
            let name = switch mode { case .sideBySide: "side-by-side"; case .slider: "slider"; case .difference: "difference"; case .toggle: "toggle" }
            assertSnapshot(of: host(view, size: CGSize(width: 820, height: 480), appearance: .aqua), as: Self.strategy, named: name)
        }

        /// The floating bar drops stats and size instead of wrapping.
        @Test func compareNarrowPane() {
            UserDefaults.standard.set(CompareMode.difference.rawValue, forKey: "compareMode")
            let app = AppModel(store: AppFixtures.store())
            ComparePairCache.store(ComparePair.make(before: AppFixtures.reference, after: AppFixtures.actual), for: "compare-narrow")
            let view = CompareView(load: { (nil, nil) }, beforeLabel: "Reference", afterLabel: "Actual", identity: "compare-narrow")
                .environmentObject(app)
            assertSnapshot(of: host(view, size: CGSize(width: 440, height: 360), appearance: .aqua), as: Self.strategy, named: "440pt")
        }

        /// Rendering noise gets a note explaining it and the precision that would pass.
        @Test func compareImperceptibleDifference() {
            UserDefaults.standard.set(CompareMode.difference.rawValue, forKey: "compareMode")
            let app = AppModel(store: AppFixtures.store())
            ComparePairCache.store(ComparePair.make(before: AppFixtures.reference, after: AppFixtures.renderingNoise), for: "compare-noise")
            let view = CompareView(load: { (nil, nil) }, beforeLabel: "Reference", afterLabel: "Actual", identity: "compare-noise")
                .environmentObject(app)
            assertSnapshot(of: host(view, size: CGSize(width: 820, height: 480), appearance: .aqua), as: Self.strategy)
        }

        /// ⇧⌘0 frames the changed pixels (here: only the button changed colour).
        @Test func compareZoomToChange() {
            UserDefaults.standard.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let app = AppModel(store: AppFixtures.store())
            ComparePairCache.store(ComparePair.make(before: AppFixtures.reference, after: AppFixtures.badged), for: "compare-zoom-change")
            let view = CompareView(load: { (nil, nil) }, beforeLabel: "Reference", afterLabel: "Actual", identity: "compare-zoom-change")
                .environmentObject(app)
            let hosted = host(view, size: CGSize(width: 820, height: 480), appearance: .aqua)
            app.zoomToChangeRequest += 1
            settle(hosted)
            #expect(app.viewport.scale > 2)
            assertSnapshot(of: hosted, as: Self.strategy)
        }

        /// The readout shown while hovering: a pixel of the button that changed colour.
        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func pixelReadout(appearance: NSAppearance.Name) {
            let view = PixelReadout(probe: PixelProbe(x: 60, y: 175),
                                    before: PixelImage(data: AppFixtures.reference), after: PixelImage(data: AppFixtures.actual),
                                    beforeLabel: "Reference", afterLabel: "Actual")
                .padding()
            assertSnapshot(of: host(view, size: CGSize(width: 480, height: 64), appearance: appearance), as: Self.strategy,
                           named: appearance == .darkAqua ? "dark" : "light")
        }

        /// Flaky pattern, then the same with Differentiate Without Color: failures hollow, mixed half filled.
        @Test(arguments: [false, true])
        func historyStrip(withoutColor: Bool) {
            let points = AppFixtures.timeline([.passed, .failed, .passed, .mixed, .failed, .passed])
            let view = HistoryStrip(points: points, size: .regular, differentiateWithoutColor: withoutColor)
                .padding()
            assertSnapshot(of: host(view, size: CGSize(width: 120, height: 48), appearance: .aqua), as: Self.strategy,
                           named: withoutColor ? "shapes" : "color")
        }

        @Test func compareZoomedIn() {
            UserDefaults.standard.set(CompareMode.sideBySide.rawValue, forKey: "compareMode")
            let app = AppModel(store: AppFixtures.store())
            app.viewport = Viewport(scale: 4, offset: CGSize(width: 120, height: -60))
            ComparePairCache.store(ComparePair.make(before: AppFixtures.reference, after: AppFixtures.actual), for: "compare-zoom")
            let view = CompareView(load: { (nil, nil) }, beforeLabel: "Reference", afterLabel: "Actual", identity: "compare-zoom")
                .environmentObject(app)
            assertSnapshot(of: host(view, size: CGSize(width: 820, height: 480), appearance: .darkAqua), as: Self.strategy, named: "dark-4x")
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
            let view = ProjectView(project: project).environmentObject(app)
            assertSnapshot(of: host(view, size: Self.paneSize, appearance: appearance), as: Self.strategy,
                           named: appearance == .darkAqua ? "dark" : "light",
                           fileID: fileID, file: file, testName: testName, line: line, column: column)
        }

        private func host<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name) -> NSView {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.isReleasedWhenClosed = false
            // Rendering the hosting view skips the window's own background, which left headers
            // transparent (white text on white in dark mode); draw it as the window would.
            let hosting = NSHostingView(rootView: deterministic(view.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))))
            hosting.frame = CGRect(origin: .zero, size: size)
            window.contentView = hosting
            settle(hosting)
            return hosting
        }

        private func deterministic<V: View>(_ view: V) -> some View {
            view
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                .environment(\.calendar, Calendar(identifier: .gregorian))
        }

        /// Lets SwiftUI finish layout and `onAppear`/`task` work that is already cached.
        private func settle(_ view: NSView) {
            for _ in 0..<3 {
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
    }
}
