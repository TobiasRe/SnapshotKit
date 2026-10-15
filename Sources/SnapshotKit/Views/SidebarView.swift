import SnapshotKitCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    private var pinned: [Project] { model.projects.filter { model.isPinned($0) } }
    private var recents: [Project] {
        let recent = Set(model.store.settings.recents)
        return model.projects.filter { recent.contains($0.path) && !model.isPinned($0) }
    }
    private var others: [Project] {
        let recent = Set(model.store.settings.recents)
        return model.projects.filter { !recent.contains($0.path) && !model.isPinned($0) }
    }

    var body: some View {
        List(selection: $model.selectedPath) {
            if !pinned.isEmpty {
                Section("Pinned") { rows(pinned) }
            }
            if !recents.isEmpty {
                Section("Recent") { rows(recents) }
            }
            Section(model.isScanning ? "Projects (scanning…)" : "Projects") {
                if others.isEmpty && pinned.isEmpty && recents.isEmpty {
                    Text("Drop a repository here, or use + below.")
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                }
                rows(others)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Add Project…") { model.addProjectFromPanel() }
                    Button("Add Scan Folder…") {
                        model.chooseFolder(message: "Choose a folder to scan for repositories with snapshot tests") { model.addScanRoot($0) }
                    }
                    Button("Rescan Folders") { model.rescan() }
                        .disabled(model.store.settings.scanRoots.isEmpty)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button { model.showQuickSwitcher = true } label: {
                    Label("⌘K", systemImage: "magnifyingglass")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Quick switch project (⌘K)")
            }
            .padding(DS.Space.s)
        }
    }

    @ViewBuilder
    private func rows(_ projects: [Project]) -> some View {
        ForEach(projects) { project in
            Label {
                Text(project.name).lineLimit(1)
            } icon: {
                Image(systemName: model.isPinned(project) ? "pin.fill" : "folder")
            }
            .badge(model.failingCounts[project.path] ?? 0)
            .help(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                  + ((model.failingCounts[project.path]).map { " — \($0) failing in the last run" } ?? ""))
            .tag(project.path)
                .contextMenu {
                    Button(model.isPinned(project) ? "Unpin" : "Pin") { model.togglePin(project) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                    Divider()
                    Button("Remove from List") { model.remove(project) }
                }
        }
    }
}

struct ProjectRow: View {
    var project: Project
    var pinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.xs) {
                Text(project.name).lineLimit(1)
                if pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text((project.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.vertical, DS.Space.xxs)
    }
}

struct QuickSwitcherView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [Project] {
        FuzzyMatcher.rank(model.projects, query: query, primary: \.name, secondary: \.path)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Switch to project…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit { choose(at: highlighted) }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                }
                .padding(DS.Space.m)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(results.prefix(50).enumerated()), id: \.element.id) { index, project in
                                HStack {
                                    ProjectRow(project: project, pinned: model.isPinned(project))
                                    Spacer()
                                    if project.path == model.selectedPath {
                                        Text("current").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, DS.Space.m)
                                .padding(.vertical, DS.Space.s)
                                .background(index == highlighted ? Color.accentColor.opacity(0.2) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { choose(at: index) }
                                .id(index)
                            }
                            if results.isEmpty {
                                Text("No matching projects").foregroundStyle(.secondary).padding()
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
                }
            }
            .frame(width: 520)
            // Floats over content, so it's glass (see docs/DESIGN.md).
            .floatingGlass(in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .padding(.top, 80)
        }
        .onAppear {
            focused = true
            if let preset = QuickSwitcherQuery.preset { query = preset }
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = (highlighted + delta + min(results.count, 50)) % min(results.count, 50)
    }

    private func choose(at index: Int) {
        guard results.indices.contains(index) else { return }
        model.open(path: results[index].path)
        close()
    }

    private func close() {
        query = ""
        model.showQuickSwitcher = false
    }
}
