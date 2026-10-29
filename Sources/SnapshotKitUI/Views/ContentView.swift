import SnapshotKitCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            if let project = model.current {
                ProjectView(project: project)
                    .id(project.project.path)
            } else {
                WelcomeView()
            }
        }
        .overlay {
            if model.showQuickSwitcher {
                QuickSwitcherView()
            }
        }
        // Drop a repository folder anywhere on the window to add and open it.
        .dropDestination(for: URL.self) { urls, _ in
            guard model.acceptsDrop(urls) else { return false }
            Task { await model.addDroppedFolders(urls) }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(DS.Space.xs)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = model.startupNotice {
                NoticeBanner(text: notice, isError: false, onClose: { model.dismissStartupNotice() })
                    .frame(maxWidth: DS.Pane.readableWidth)
                    .floatingGlass(in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
                    .padding()
            }
        }
        // For the Services menu's Open in SnapshotKit, which brings the window back if it was closed.
        .onAppear { MainWindow.openWindow = openWindow }
        // The Dock icon counts the open project's failing tests: from launch, and as you switch.
        .onChange(of: model.current?.dockBadge, initial: true) { _, badge in
            guard !DS.solidSurfaces else { return }
            NSApp.dockTile.badgeLabel = badge
        }
        // A scan's result is read out like a run's.
        .onChange(of: model.startupNotice) { _, notice in
            guard let notice else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: notice.replacingOccurrences(of: "`", with: "")])
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: DS.Space.xl) {
            VStack(spacing: DS.Space.s) {
                // The app icon in the built app (compiled into its asset catalog); a symbol in
                // debug builds and tests, which have none.
                if let icon = NSImage(named: "app-icon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text("All your snapshots in one place")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Add a repository that uses swift-snapshot-testing.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: DS.Space.m) {
                feature("square.grid.2x2", "Browse and inspect", "Every reference image by module and test, with variants and history.")
                feature("arrow.triangle.branch", "Review changes", "What differs from your base branch, side by side or as a difference.")
                feature("camera", "Update", "Re-record any test, suite or filtered set; fix failing and flaky ones.")
            }
            .frame(maxWidth: 440)
            HStack {
                Button("Add Project…") { model.addProjectFromPanel() }
                    .primaryActionStyle()
                Button("Add Scan Folder…") { model.addScanRootFromPanel() }
                    .fixedSize()
                    .quietControl()
            }
            Text("Or drop a repository onto this window. ⌘K finds projects and commands.")
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Surface.content)
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(DS.Font.heading)
                Text(detail).font(DS.Font.secondary).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct NoticeBanner: View {
    var text: String
    var isError: Bool
    /// A next step, e.g. ("Review Changes", go there).
    var action: (title: String, run: () -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            // Failed is a red circle everywhere; the triangle means a warning.
            Image(systemName: isError ? "xmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(isError ? DS.Status.failed : Color.secondary)
                // Its symbol's name would sound like the close button beside it.
                .accessibilityLabel(isError ? "Error" : "Note")
            Text(StatusNote.code(text, font: DS.Font.secondary.monospaced()))
                .font(DS.Font.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action.title, action: action.run)
                    .quietControl()
                    .controlSize(.small)
                    .fixedSize()
            }
            if let onClose {
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
                    .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
    }
}
