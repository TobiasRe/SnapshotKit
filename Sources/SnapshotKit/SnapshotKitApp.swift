import AppKit
import SnapshotKitCore
import SwiftUI

@main
struct SnapshotKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared
    /// Bound by the menu bar scene; a small object of its own rather than a property of `model`.
    private let menuBar = AppModel.shared.menuBar

    var body: some Scene {
        WindowGroup("SnapshotKit", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1400, height: 880)
        .commands { SnapshotKitCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }

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
    }
}

extension AppModel {
    static let shared = AppModel()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Built as a plain executable, so opt into being a regular foreground app.
        let capture = CaptureOptions.parse(CommandLine.arguments)
        NSApp.setActivationPolicy(capture == nil ? .regular : .accessory)
        if capture == nil { NSApp.activate(ignoringOtherApps: true) }
        InterruptGuard.install()
        if let capture {
            Task { await WindowCapture.run(capture, model: AppModel.shared) }
        }
    }

    /// `snapshotkit://compare?reference=…&actual=…`, from `snapkit open` (the diff tool) or a link.
    /// Taken as the Apple event itself: SwiftUI would otherwise route it to a scene and open
    /// another main window instead of a compare window.
    func applicationWillFinishLaunching(_ notification: Notification) {
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

struct SnapshotKitCommands: Commands {
    var model: AppModel
    @AppStorage("compareMode") private var compareMode = CompareMode.sideBySide.rawValue

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Project…") { model.addProjectFromPanel() }
                .keyboardShortcut("o")
            Button("Import Result Bundle…") { model.importResultBundleFromPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.current == nil)
            Divider()
            Button("Go to Project or Command…") { model.showQuickSwitcher.toggle() }
                .keyboardShortcut("k")
        }
        CommandMenu("Snapshots") {
            let project = model.current
            let busy = project?.isRunning ?? true
            Button("Run Snapshot Tests") { project?.runTests() }
                .keyboardShortcut("r")
                .disabled(busy)
            Divider()
            Button("Re-record Selected Test") { project?.reRecordSelection() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!(project?.canReRecordSelection ?? false))
            Button("Open Test in Xcode") { if let file = project?.selectedSnapshotFile { project?.openTestInXcode(file) } }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(project?.selectedSnapshotFile == nil)
            Button("Re-record Failing Suites") { project?.reRecordFailed() }
                .keyboardShortcut("r", modifiers: [.command, .shift, .option])
                .disabled(busy || (project?.failingSuites.isEmpty ?? true))
            Button("Re-record All Snapshot Tests…") { project?.confirmReRecordAll = true }
                .disabled(busy || project?.environment == nil || (project?.recordableSnapshots.isEmpty ?? true))
            Button("Check Flakiness of Failed Tests") { project?.checkFlakiness() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(busy || (project?.failingSuites.isEmpty ?? true))
            Divider()
            Button("Run on Remote Machine") { project?.runRemote() }
                .keyboardShortcut("r", modifiers: [.command, .control])
                .disabled(busy || !(project?.hasRemote ?? false))
            Divider()
            Button("Cancel") { project?.cancel() }
                .keyboardShortcut(".")
                .disabled(!(project?.isRunning ?? false))
        }
        CommandGroup(after: .toolbar) {
            if let project = model.current {
                Button("Filter…") { project.focusFilterRequest += 1 }.keyboardShortcut("f")
                Divider()
                Button("Snapshots") { project.tab = .snapshots }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Changes") { project.tab = .changes }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Failures") { project.tab = .failures }.keyboardShortcut("3", modifiers: [.command, .option])
                Button("Run") { project.tab = .run }.keyboardShortcut("4", modifiers: [.command, .option])
                Divider()
                // Step through snapshots even while the image, not the list, has focus.
                Button("Next Item") { project.selectAdjacent(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(project.tab == .run)
                Button("Previous Item") { project.selectAdjacent(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(project.tab == .run)
                Button("Toggle Viewed") {
                    if let change = project.selectedChange { project.setViewed(!project.viewedChanges.contains(change.id), for: change) }
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
            Button("Zoom In") { model.viewport.zoomIn() }
                .keyboardShortcut("=")
            Button("Zoom Out") { model.viewport.zoomOut() }
                .keyboardShortcut("-")
            Button("Actual Size / Fit") { model.viewport.reset() }
                .keyboardShortcut("0")
            Button("Zoom to Change") { model.zoomToChangeRequest += 1 }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            Divider()
        }
    }
}
