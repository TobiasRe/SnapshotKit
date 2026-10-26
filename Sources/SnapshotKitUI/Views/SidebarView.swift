import SnapshotKitCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    private var pinned: [Project] { model.projects.filter { model.isPinned($0) } }
    /// Recent is a shortcut into a long list; in a short one every project is in view already, and
    /// listing some twice only doubled the rows.
    static let recentsAbove = 8
    private var recents: [Project] {
        guard all.count > Self.recentsAbove else { return [] }
        let recent = Set(model.store.settings.recents)
        return model.projects.filter { recent.contains($0.path) && !model.isPinned($0) }
    }
    /// The projects not pinned, alphabetically, in a fixed place: opening one adds it to Recent but
    /// doesn't take it out of here.
    private var all: [Project] {
        model.projects.filter { !model.isPinned($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// In a long list recent projects appear twice, so their shortcut rows get their own tags: a
    /// click there highlights that row, not both.
    private static let shortcutTags = ["recent:"]
    @State private var clickedTag: String?

    private static func path(of tag: String) -> String {
        for prefix in shortcutTags where tag.hasPrefix(prefix) { return String(tag.dropFirst(prefix.count)) }
        return tag
    }

    private var selection: Binding<String?> {
        Binding(
            get: {
                guard let path = model.selectedPath else { return nil }
                return clickedTag.map(Self.path(of:)) == path ? clickedTag : path
            },
            set: { tag in
                clickedTag = tag
                model.selectedPath = tag.map(Self.path(of:))
            })
    }

    var body: some View {
        List(selection: selection) {
            if !pinned.isEmpty {
                Section("Pinned") { rows(pinned) }
            }
            if !recents.isEmpty {
                Section("Recent") { rows(recents, tagPrefix: "recent:") }
            }
            // Not when every project is pinned: a heading over nothing.
            if !all.isEmpty || model.projects.isEmpty || model.isScanning {
                Section(model.isScanning ? "Projects (scanning…)" : "Projects") {
                    if model.projects.isEmpty {
                        Text("Drop a repository here, or use + below.")
                            .font(DS.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    rows(all)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Add Project…") { model.addProjectFromPanel() }
                    Button("Add Scan Folder…") { model.addScanRootFromPanel() }
                    Button("Rescan Folders") { model.rescan() }
                        .disabled(model.store.settings.scanRoots.isEmpty)
                } label: {
                    // Titled, so VoiceOver reads "Add" rather than the symbol's name.
                    Label("Add", systemImage: "plus").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a project or a folder to scan")
                Spacer()
                Button { model.showQuickSwitcher = true } label: {
                    Label("⌘K", systemImage: "magnifyingglass")
                        .labelStyle(.titleAndIcon)
                        .font(DS.Font.caption)
                }
                .buttonStyle(.borderless)
                .help("Projects and commands (⌘K)")
                // Shows "⌘K"; says what it opens.
                .accessibilityLabel("Go to Project or Command")
            }
            .padding(.horizontal, DS.Space.m)
            // Level with the lists' footers.
            .frame(height: DS.Bar.footer)
        }
    }

    @ViewBuilder
    private func rows(_ projects: [Project], tagPrefix: String = "") -> some View {
        ForEach(projects) { project in
            Label {
                HStack(spacing: DS.Space.s) {
                    Text(project.name).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: DS.Space.xs)
                    // A failing count is status, so it carries the failed colour (the system
                    // badge would be a plain grey number).
                    if let failing = model.failingCounts[project.path], failing > 0 {
                        FailingCount(count: failing)
                    }
                }
            } icon: {
                ProjectMonogram(name: project.name)
            }
            // One VoiceOver stop per project, its failing count included ("Chat, 4 failing").
            .accessibilityElement(children: .combine)
            // The sidebar keeps the system's selection: on its material it is already as quiet
            // as the lists' (about +15 levels in dark, like Linear's).
            .help(project.path.abbreviatingWithTildeInPath
                  + (model.failingCounts[project.path].map { " — \($0) failing in the last run" } ?? ""))
            .tag(tagPrefix + project.path)
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
            .font(DS.Font.monogram)
            .monogramTile()
    }
}

extension View {
    /// The small neutral tile of a project monogram, also behind a palette command's icon.
    func monogramTile() -> some View {
        self
            .foregroundStyle(Color.primary.opacity(0.7))
            .frame(width: DS.Control.monogram, height: DS.Control.monogram)
            .background(RoundedRectangle(cornerRadius: DS.Radius.tiny, style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.tiny, style: .continuous).strokeBorder(DS.Surface.hairline))
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
                .foregroundStyle(.secondary)
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
        (path as NSString).deletingLastPathComponent.abbreviatingWithTildeInPath
    }
}

struct QuickSwitcherView: View {
    @Environment(AppModel.self) private var model
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
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("", text: $query)
                        .textFieldStyle(.plain)
                        .placeholder("Go to a project or run a command…", shown: query.isEmpty)
                        .font(.title3)
                        .accessibilityLabel("Go to a project or run a command")
                        .focused($focused)
                        .onSubmit { choose(at: highlighted) }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        // The palette is modal: Tab (and Shift-Tab, a backtab) would otherwise move
                        // focus to the window behind it.
                        .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { _ in .handled }
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
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { choose(at: index) }
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
            // VoiceOver stays in the palette, as Tab does, until it closes.
            .accessibilityAddTraits(.isModal)
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
        // Focus stays in the field, so VoiceOver wouldn't otherwise say where the highlight went.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: shown[highlighted].title])
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
