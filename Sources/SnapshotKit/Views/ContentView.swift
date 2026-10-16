import SnapshotKitCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
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
            model.addDroppedFolders(urls)
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
                NoticeBanner(text: notice, isError: false) { model.dismissStartupNotice() }
                    .frame(maxWidth: 520)
                    .floatingGlass(in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                    .padding()
            }
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: DS.Space.xl) {
            VStack(spacing: DS.Space.s) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("All your snapshots in one place")
                    .font(.title2.weight(.semibold))
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
                Button("Add Scan Folder…") {
                    model.chooseFolder(message: "Choose a folder to scan for repositories with snapshot tests") { model.addScanRoot($0) }
                }
                .secondaryActionStyle()
            }
            Text("Or drop a repository onto this window. ⌘K finds projects and commands.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct NoticeBanner: View {
    var text: String
    var isError: Bool
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isError ? DS.Status.failed : Color.secondary)
            Text(text)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
