import AppKit
import SnapshotKitCore
import SwiftUI

/// A reference and the image a test produced instead, opened from outside the app: `snapkit open`,
/// the diff tool swift-snapshot-testing names in a failure message, opens a `snapshotkit://compare`
/// URL, and this window shows the pair with the same compare view as the Failures tab.
struct CompareWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    var request: CompareRequest
    /// Where the reference lives, when it's in a git repository: what "Show in Project" opens.
    var location: (repository: URL, path: String)?
    /// Room for the window's traffic lights: the header is the window's title bar.
    var leadingInset: CGFloat = 0

    private var file: SnapshotFile { SnapshotFile(path: location?.path ?? request.reference.path, byteSize: 0) }

    var title: String { file.variant.isEmpty ? file.testName : "\(file.testName) · \(file.variant)" }

    private var subtitle: String {
        guard let location else {
            return request.reference.deletingLastPathComponent().path.abbreviatingWithTildeInPath
        }
        let module = SnapshotModules.module(forSnapshotPath: location.path)
        return location.repository.lastPathComponent + " › " + Breadcrumb.of(module: module, suite: file.suite)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneBar(height: DS.Bar.header) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title).font(DS.Font.heading).lineLimit(1)
                    Text(subtitle)
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(request.reference.path)
                Spacer(minLength: DS.Space.m)
                if let location {
                    Button("Show in Project") { showInProject(location) }
                        .fixedSize()
                        .quietControl()
                        .help("Open \(location.repository.lastPathComponent) in SnapshotKit and select this snapshot")
                }
                GlassIconButton(title: "Reveal in Finder", symbol: "folder",
                                help: "Reveal both images in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([request.reference, request.actual])
                }
            }
            .padding(.leading, leadingInset)
            .background(DS.Surface.content)
            Divider()
            CompareView(load: { [reference = request.reference, actual = request.actual] in
                            (try? Data(contentsOf: reference), try? Data(contentsOf: actual))
                        },
                        beforeLabel: "Reference",
                        afterLabel: "Actual",
                        identity: Self.identity(of: request))
        }
        .ignoresSafeArea(edges: .top)
    }

    /// Changes with the files, so re-running the test and opening the pair again shows the new image.
    static func identity(of request: CompareRequest) -> String {
        let stamp = { (url: URL) in
            ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970)
                .map { String($0) } ?? ""
        }
        return "compare:\(request.reference.path)#\(stamp(request.reference)):\(request.actual.path)#\(stamp(request.actual))"
    }

    private func showInProject(_ location: (repository: URL, path: String)) {
        app.reveal(snapshot: location.path, in: location.repository)
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            main.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

/// One window per compared pair: opening the same pair again brings its window forward.
@MainActor
enum CompareWindows {
    private static var windows: [CompareRequest: NSWindow] = [:]

    static func show(_ request: CompareRequest) {
        // Closed windows stay alive (`isReleasedWhenClosed` is off) until they're let go of here.
        windows = windows.filter { $0.value.isVisible || $0.value.isMiniaturized }
        if let window = windows[request] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = CompareWindow(request: request, location: request.location, leadingInset: 72)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // A unified toolbar makes the title bar as tall as the header, which then sits in it beside
        // the traffic lights, as the main window's toolbar does; the title is for the Window menu.
        window.title = view.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "compare")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.contentView = NSHostingView(rootView: view.environment(AppModel.shared))
        window.center()
        window.setFrameAutosaveName("CompareWindow")
        windows[request] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
