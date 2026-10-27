import AppKit
import SnapshotKitCore
import SwiftUI

/// The app, started by the SnapshotKit target of SnapshotKit.xcodeproj.
public struct SnapshotKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared
    /// Bound by the menu bar scene; a small object of its own rather than a property of `model`.
    private let menuBar = AppModel.shared.menuBar

    public init() {}

    public var body: some Scene {
        // One window: every view of it shows the same model, so a second one would only mirror it.
        Window("SnapshotKit", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1400, height: 880)
        .defaultAppStorage(.app)
        .commands { SnapshotKitCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
        .defaultAppStorage(.app)

        // Optional (Settings > General): run progress and quick access from the menu bar.
        MenuBarExtra(isInserted: Binding(get: { menuBar.isShown },
                                         // SwiftUI writes the current value back while updating; publishing
                                         // that would rebuild the app's scenes again, endlessly.
                                         set: { if $0 != menuBar.isShown { menuBar.isShown = $0 } })) {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
        .defaultAppStorage(.app)
    }
}

extension UserDefaults {
    /// Where the app keeps view settings (compare mode, layout, column width, library sort). A
    /// `--capture` run gets a scratch suite, so showing a screen in some mode never changes the user's
    /// own choice. `SNAPSHOTKIT_DEFAULTS` names another suite, or a plist by its path without
    /// `.plist`, as the tests do, like `SNAPSHOTKIT_HOME` for the settings.
    /// `nonisolated(unsafe)`: UserDefaults is thread-safe, just not marked Sendable.
    nonisolated(unsafe) static let app: UserDefaults = {
        if let name = ProcessInfo.processInfo.environment["SNAPSHOTKIT_DEFAULTS"], !name.isEmpty,
           let suite = UserDefaults(suiteName: name) {
            return suite
        }
        guard CaptureOptions.parse(CommandLine.arguments) != nil else { return .standard }
        let name = "org.snapshotkit.SnapshotKit.capture"
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name) ?? .standard
    }()
}

extension AppModel {
    static let shared = AppModel()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A capture draws off-screen: no Dock icon, and the frontmost app stays in front.
        let capture = CaptureOptions.parse(CommandLine.arguments)
        if capture != nil { NSApp.setActivationPolicy(.accessory) }
        InterruptGuard.install()
        if let capture {
            Task { await WindowCapture.run(capture, model: AppModel.shared) }
        }
    }

    /// `snapshotkit://compare?reference=…&actual=…`, from `snapkit open` (the diff tool) or a link.
    /// Taken as the Apple event itself: SwiftUI would otherwise route it to a scene and open
    /// another main window instead of a compare window.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A single-window app: no window tabs, nor their View menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
        // A capture skips window restoration, as UI tests do. Started from its executable rather than by Launch
        // Services, the app otherwise opens no window; and it shares the installed app's bundle id, whose
        // windows it shouldn't restore or save.
        if CaptureOptions.parse(CommandLine.arguments) != nil {
            UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @objc private func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), let request = CompareRequest(url: url) else { return }
        CompareWindows.show(request)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.applicationWillTerminate()
    }

    /// With the menu bar item shown, closing the window keeps SnapshotKit (and its runs) going.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.shared.menuBar.isShown
    }
}

/// The one main window, wherever something asks for it: the Window menu, the menu bar panel, a
/// compare window's Show in Project.
@MainActor
enum MainWindow {
    static func isMain(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }

    /// Brings the main window forward, opening it again if it was closed: a closed window stays in
    /// `NSApp.windows`, just not visible.
    static func show(_ openWindow: OpenWindowAction) {
        if !NSApp.windows.contains(where: { isMain($0) && $0.isVisible }) {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: isMain)?.makeKeyAndOrderFront(nil)
    }
}

struct SnapshotKitCommands: Commands {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("compareMode") private var compareMode = CompareMode.sideBySide.rawValue

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Project…") { model.addProjectFromPanel() }
                .keyboardShortcut("o")
            Button("Import Result Bundle…") { model.importResultBundleFromPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.current == nil || model.current?.isRunning == true)
            Button("Load Failed CI Job…") { model.loadCIJobFromPrompt() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.current == nil || model.current?.isRunning == true)
            Divider()
            Button("Go to Project or Command…") { model.showQuickSwitcher.toggle() }
                .keyboardShortcut("k")
        }
        CommandMenu("Snapshots") {
            let project = model.current
            let busy = project?.isRunning ?? true
            // Without Xcode and a simulator nothing runs locally: the same rule as the Run tab and ⌘K.
            let cantRun = busy || project?.environment == nil
            Button("Run Snapshot Tests") { project?.runTests() }
                .keyboardShortcut("r")
                .disabled(cantRun)
            Divider()
            Button(project?.reRecordSelectionTitle ?? "Re-record Selected Test") { project?.reRecordSelection() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!(project?.canReRecordSelection ?? false))
            Button("Open Test in Xcode") { if let file = project?.testToOpen { project?.openTestInXcode(file) } }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(project?.testToOpen == nil)
            Button("Re-record Failing Suites") { project?.reRecordFailed() }
                .keyboardShortcut("r", modifiers: [.command, .shift, .option])
                .disabled(cantRun || (project?.failingSuites.isEmpty ?? true))
            Button("Re-record All Snapshot Tests…") { project?.confirmReRecordAll = true }
                .disabled(cantRun || (project?.recordableSnapshots.isEmpty ?? true))
            Button("Check Flakiness of Failing Tests") { project?.checkFlakiness() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(cantRun || (project?.failingSuites.isEmpty ?? true))
            Divider()
            Button("Run on Remote Machine") { project?.runRemote() }
                .keyboardShortcut("r", modifiers: [.command, .control])
                .disabled(busy || !(project?.hasRemote ?? false))
            Divider()
            // Named as in the palette: "Cancel" alone says nothing in a menu.
            Button("Cancel Run") { project?.cancel() }
                .keyboardShortcut(".")
                .disabled(!(project?.isRunning ?? false))
        }
        CommandGroup(after: .toolbar) {
            if let project = model.current {
                // The Failures list has no filter field to focus.
                Button("Filter…") { project.focusFilterRequest += 1 }.keyboardShortcut("f")
                    .disabled(project.tab == .failures)
                Divider()
                Button("Snapshots") { project.tab = .snapshots }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Changes") { project.tab = .changes }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Failures") { project.tab = .failures }.keyboardShortcut("3", modifiers: [.command, .option])
                Button("Run") { project.tab = .run }.keyboardShortcut("4", modifiers: [.command, .option])
                Divider()
                // Step through snapshots even while the image, not the list, has focus.
                Button("Previous Item") { project.selectAdjacent(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(project.tab == .run)
                Button("Next Item") { project.selectAdjacent(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(project.tab == .run)
                // Says which way it goes, like the list's context menu.
                let viewed = project.selectedChange.map { project.viewedChanges.contains($0.id) } ?? false
                Button(viewed ? "Mark as Not Viewed" : "Mark as Viewed") {
                    if let change = project.selectedChange { project.setViewed(!viewed, for: change) }
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(project.tab != .changes || project.selectedChange == nil)
                Divider()
            }
            Picker("Compare", selection: $compareMode) {
                Text("Side by Side").tag(CompareMode.sideBySide.rawValue).keyboardShortcut("1")
                Text("Slider").tag(CompareMode.slider.rawValue).keyboardShortcut("2")
                Text("Difference").tag(CompareMode.difference.rawValue).keyboardShortcut("3")
                Text("Toggle").tag(CompareMode.toggle.rawValue).keyboardShortcut("4")
            }
            .pickerStyle(.inline)
            Divider()
            Button("Zoom In") { model.activeCompare.viewport.zoomIn() }
                .keyboardShortcut("=")
            Button("Zoom Out") { model.activeCompare.viewport.zoomOut() }
                .keyboardShortcut("-")
            Button("Zoom to Fit") { model.activeCompare.viewport.reset() }
                .keyboardShortcut("0")
            Button("Zoom to Change") { model.activeCompare.zoomToChangeRequest += 1 }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            Divider()
        }
        CommandGroup(after: .windowArrangement) {
            // The Window menu doesn't list a closed main window, and with the menu bar item shown
            // SnapshotKit outlives it: this brings it back without the Dock.
            Button("SnapshotKit") { MainWindow.show(openWindow) }
        }
    }
}
