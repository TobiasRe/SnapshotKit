import SnapshotKitCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

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
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No project selected")
                .font(.title2.weight(.semibold))
            Text("Add a repository with snapshot tests, or a folder to scan for them.")
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill((isError ? Color.red : Color.accentColor).opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder((isError ? Color.red : Color.accentColor).opacity(0.2)))
    }
}
