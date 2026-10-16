import AppKit
import SnapshotKitCore
import SnapshotTesting
import SwiftUI
import Testing
@testable import SnapshotKit

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

    @Test func welcome() {
        let app = AppModel(store: AppFixtures.store())
        let view = WelcomeView().environmentObject(app)
        assertSnapshot(of: host(view, size: CGSize(width: 700, height: 460), appearance: .aqua), as: Self.strategy)
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
