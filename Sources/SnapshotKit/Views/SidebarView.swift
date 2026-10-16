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
                .help("Projects and commands (⌘K)")
            }
            .padding(.horizontal, DS.Space.m)
            // Level with the lists' footers.
            .frame(height: DS.Bar.footer)
        }
    }

    @ViewBuilder
    private func rows(_ projects: [Project]) -> some View {
        ForEach(projects) { project in
            Label {
                Text(project.name).fontWeight(.medium).lineLimit(1)
            } icon: {
                ProjectMonogram(name: project.name)
            }
            // The sidebar keeps the system's selection: on its material it is already as quiet
            // as the lists' (about +15 levels in dark, like Linear's).
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

/// A project's initials in a small neutral tile: tells projects apart at a glance where identical
/// folder icons didn't, without spending colour (colour means status).
struct ProjectMonogram: View {
    var name: String

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(1))
        return String(letters).uppercased()
    }

    var body: some View {
        Text(Self.initials(name))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.7))
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(DS.Surface.hairline))
            .accessibilityHidden(true)
    }
}

/// One line per project, like a command palette: monogram, name, where it lives, and a quiet
/// highlight that follows the arrow keys.
struct QuickSwitcherRow: View {
    var project: Project
    var pinned: Bool
    var current: Bool
    var highlighted: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ProjectMonogram(name: project.name)
            Text(project.name).fontWeight(.medium).lineLimit(1).layoutPriority(1)
            if pinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary).accessibilityLabel("Pinned")
            }
            Spacer(minLength: DS.Space.m)
            Text(current ? "Current" : Self.location(project.path))
                .font(DS.Font.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, DS.Space.s)
        .frame(height: QuickSwitcherView.rowHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(highlighted ? DS.Surface.selection : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    /// The folder that holds the project, with the home folder as "~".
    static func location(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

struct QuickSwitcherView: View {
    @EnvironmentObject private var model: AppModel
    // Starts with a preset query (captures, tests), so the first layout is already the final one.
    @State private var query = QuickSwitcherQuery.preset ?? ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [PaletteItem] {
        PaletteItem.ranked(projects: model.projects, commands: PaletteCommand.available(app: model), query: query)
    }
    private var shown: [PaletteItem] { Array(results.prefix(50)) }
    static let rowHeight: CGFloat = 36

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Go to a project or run a command…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit { choose(at: highlighted) }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                }
                .padding(.horizontal, DS.Space.l)
                .frame(height: DS.Bar.header)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                                Group {
                                    switch item {
                                    case .project(let project):
                                        QuickSwitcherRow(project: project, pinned: model.isPinned(project),
                                                         current: project.path == model.selectedPath, highlighted: index == highlighted)
                                    case .command(let command):
                                        PaletteCommandRow(command: command, highlighted: index == highlighted)
                                    }
                                }
                                .onTapGesture { choose(at: index) }
                                .id(index)
                            }
                            if results.isEmpty {
                                Text("No matching projects or commands")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                            }
                        }
                        .padding(DS.Space.xs)
                    }
                    // As tall as its results, up to nine rows: no empty panel under two matches.
                    .frame(height: CGFloat(min(max(shown.count, 1), 9)) * Self.rowHeight + DS.Space.s)
                    .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
                }
            }
            .frame(width: 520)
            // Floats over content, so it's glass (see docs/design.md).
            .floatingGlass(in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .padding(.top, 80)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        highlighted = (highlighted + delta + shown.count) % shown.count
    }

    private func choose(at index: Int) {
        guard shown.indices.contains(index) else { return }
        let item = shown[index]
        close()
        switch item {
        case .project(let project): model.open(path: project.path)
        case .command(let command): command.run()
        }
    }

    private func close() {
        query = ""
        model.showQuickSwitcher = false
    }
}
