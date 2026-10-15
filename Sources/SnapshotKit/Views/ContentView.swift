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
                    .padding()
            }
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No project selected")
                .font(.title2.weight(.semibold))
            Text("Drop a repository with snapshot tests here, or add a folder to scan for them.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Add Project…") { model.addProjectFromPanel() }
                Button("Add Scan Folder…") {
                    model.chooseFolder(message: "Choose a folder to scan for repositories with snapshot tests") { model.addScanRoot($0) }
                }
            }
            Text("Press ⌘K to switch projects quickly.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoticeBanner: View {
    var text: String
    var isError: Bool
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isError ? .red : .accentColor)
            Text(text)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onClose {
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).fill((isError ? Color.red : Color.accentColor).opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).strokeBorder((isError ? Color.red : Color.accentColor).opacity(0.2)))
    }
}
