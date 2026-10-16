import AppKit
import SnapshotKitCore
import SwiftUI

/// Headless screenshots of the full window, for automated UI verification:
///
///     SnapshotKit --capture out.png --project /path/to/repo --tab changes \
///                 [--select <change path | failure id>] [--compare side-by-side|slider|difference|toggle]
///                 [--zoom 3|change] [--pan 40,-20] [--quick-switcher [query]] [--import-xcresult PATH]
///                 [--action run|rerecord|flaky|remote] [--size 1400x880] [--appearance light|dark] [--timeout 600]
///
/// The window is placed off-screen and the app does not activate, so it does not disturb
/// whatever is on screen. Set SNAPSHOTKIT_HOME to keep captures away from real settings.
struct CaptureOptions: Equatable {
    var output: String
    var project: String?
    var tab: ProjectTab?
    var select: String?
    var compare: CompareMode?
    var zoom: CGFloat?
    var zoomToChange = false
    var pan: CGSize?
    var quickSwitcher: String?
    var importBundle: String?
    var action: String?
    var size = CGSize(width: 1400, height: 880)
    var appearance: String?
    var timeout: TimeInterval = 900

    static func parse(_ args: [String]) -> CaptureOptions? {
        guard let i = args.firstIndex(of: "--capture"), i + 1 < args.count else { return nil }
        var o = CaptureOptions(output: args[i + 1])
        func value(_ name: String) -> String? {
            guard let j = args.firstIndex(of: name), j + 1 < args.count, !args[j + 1].hasPrefix("--") else { return nil }
            return args[j + 1]
        }
        o.project = value("--project")
        o.tab = value("--tab").flatMap { v in ProjectTab.allCases.first { $0.rawValue.lowercased() == v.lowercased() } }
        o.select = value("--select")
        o.compare = value("--compare").flatMap { v in
            switch v.lowercased() {
            case "side-by-side", "sidebyside": .sideBySide
            case "slider": .slider
            case "difference", "diff": .difference
            case "toggle": .toggle
            default: nil
            }
        }
        o.zoom = value("--zoom").flatMap(Double.init).map { CGFloat($0) }
        o.zoomToChange = value("--zoom") == "change"
        if let pan = value("--pan")?.split(separator: ","), pan.count == 2, let x = Double(pan[0]), let y = Double(pan[1]) {
            o.pan = CGSize(width: x, height: y)
        }
        if args.contains("--quick-switcher") { o.quickSwitcher = value("--quick-switcher") ?? "" }
        o.importBundle = value("--import-xcresult")
        o.action = value("--action")
        if let size = value("--size")?.split(separator: "x"), size.count == 2, let w = Double(size[0]), let h = Double(size[1]) {
            o.size = CGSize(width: w, height: h)
        }
        if let t = value("--timeout").flatMap(Double.init) { o.timeout = t }
        o.appearance = value("--appearance")
        return o
    }
}

@MainActor
enum WindowCapture {
    static func run(_ o: CaptureOptions, model: AppModel) async {
        let deadline = Date().addingTimeInterval(o.timeout)
        func log(_ s: String) { FileHandle.standardError.write(Data("capture: \(s)\n".utf8)) }

        DS.solidSurfaces = true
        if let appearance = o.appearance {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let path = o.project { model.open(path: path) }
        guard let window = await waitFor(deadline: Date().addingTimeInterval(15), { mainWindow() }) else {
            log("no window appeared"); exit(3)
        }
        window.setFrame(NSRect(x: -30000, y: -30000, width: o.size.width, height: o.size.height), display: true)
        if let mode = o.compare { UserDefaults.standard.set(mode.rawValue, forKey: "compareMode") }

        if let project = model.current {
            if let tab = o.tab { project.tab = tab }
            // Wait for the environment check so actions can start.
            _ = await waitFor(deadline: Date().addingTimeInterval(60)) {
                (project.environment != nil || project.environmentError != nil || project.configError != nil) ? true : nil
            }
            if let bundle = o.importBundle {
                project.importResultBundle(URL(fileURLWithPath: bundle))
                _ = await waitFor(deadline: Date().addingTimeInterval(120)) { project.failureSource?.host == "imported" ? true : nil }
                if let tab = o.tab { project.tab = tab }
            }
            if let action = o.action {
                log("running \(action)…")
                switch action {
                case "run": project.runTests()
                case "rerecord": project.reRecordFailed()
                case "flaky": project.checkFlakiness()
                case "remote": project.runRemote()
                default: log("unknown action \(action)")
                }
                _ = await waitFor(deadline: deadline) { project.isRunning ? nil : true }
                log("action finished: \(project.lastMessage ?? "-")")
                if let tab = o.tab { project.tab = tab }
            }
            _ = await waitFor(deadline: Date().addingTimeInterval(30)) { project.isLoadingChanges ? nil : true }
            if let select = o.select {
                switch project.tab {
                case .failures: project.selectedFailureID = select
                case .snapshots: project.selectedSnapshotID = select
                default: project.selectedChangeID = select
                }
            }
        }
        if let zoom = o.zoom { model.viewport = Viewport(scale: zoom, offset: o.pan ?? .zero) }
        else if let pan = o.pan { model.viewport.pan(by: pan) }
        if let query = o.quickSwitcher {
            if !query.isEmpty { QuickSwitcherQuery.preset = query }
            model.showQuickSwitcher = true
        }

        // Let SwiftUI lay out and the image decode/diff tasks finish.
        try? await Task.sleep(for: .seconds(2.5))
        if o.zoomToChange {
            model.zoomToChangeRequest += 1
            try? await Task.sleep(for: .seconds(1))
        }
        guard let png = render(window) else { log("render failed"); exit(4) }
        do {
            try png.write(to: URL(fileURLWithPath: o.output))
            log("wrote \(o.output) (\(Int(o.size.width))×\(Int(o.size.height)) pt)")
            exit(0)
        } catch {
            log("could not write \(o.output): \(error.localizedDescription)")
            exit(5)
        }
    }

    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.contentView != nil && $0.isVisible && !($0 is NSPanel) && $0.frame.width > 100 }
    }

    /// Renders the window's frame view (title bar, toolbar and content) at backing resolution.
    static func render(_ window: NSWindow) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    static func waitFor<T>(deadline: Date, _ condition: () -> T?) async -> T? {
        while Date() < deadline {
            if let value = condition() { return value }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }
}

/// Lets a capture pre-fill the quick switcher's search field.
@MainActor
enum QuickSwitcherQuery {
    static var preset: String?
}
