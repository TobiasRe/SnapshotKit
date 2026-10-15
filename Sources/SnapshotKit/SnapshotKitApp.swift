import AppKit
import SnapshotKitCore
import SwiftUI

@main
struct SnapshotKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("SnapshotKit", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1400, height: 880)
        .commands { SnapshotKitCommands(model: model) }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

extension AppModel {
    static let shared = AppModel()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Built as a plain executable, so opt into being a regular foreground app.
        let capture = CaptureOptions.parse(CommandLine.arguments)
        NSApp.setActivationPolicy(capture == nil ? .regular : .accessory)
        if capture == nil { NSApp.activate(ignoringOtherApps: true) }
        InterruptGuard.install()
        if let capture {
            Task { @MainActor in await WindowCapture.run(capture, model: AppModel.shared) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.applicationWillTerminate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct SnapshotKitCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Project…") { model.addProjectFromPanel() }
                .keyboardShortcut("o")
            Button("Import Result Bundle…") { model.importResultBundleFromPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.current == nil)
            Divider()
            Button("Quick Switch Project…") { model.showQuickSwitcher.toggle() }
                .keyboardShortcut("k")
        }
        CommandMenu("Tests") {
            let project = model.current
            let busy = project?.isRunning ?? true
            Button("Run Snapshot Tests") { project?.runTests() }
                .keyboardShortcut("r")
                .disabled(busy)
            Button("Re-record Failed Suites") { project?.reRecordFailed() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(busy || (project?.failingSuites.isEmpty ?? true))
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
            Button("Zoom In") { model.viewport.zoomIn() }
                .keyboardShortcut("=")
            Button("Zoom Out") { model.viewport.zoomOut() }
                .keyboardShortcut("-")
            Button("Actual Size / Fit") { model.viewport.reset() }
                .keyboardShortcut("0")
            Divider()
        }
    }
}
