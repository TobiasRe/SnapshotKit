import SnapshotKitCore
import SwiftUI

/// One project at a time: the switcher on top, and under it what there is to look at in it.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let project = model.current {
                SectionList(project: project)
            } else {
                // Keeps the sidebar's material while no project is open; the switcher says what to do.
                List {}.listStyle(.sidebar)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ProjectSwitcher() }
    }
}

/// The open project's sections, grouped as they're used: what you changed, what the tests say,
/// and everything there is.
struct SectionList: View {
    let project: ProjectModel

    var body: some View {
        List(selection: Binding(get: { project.section }, set: { if let section = $0 { project.section = section } })) {
            Section("Workspace") {
                row(.workingCopy)
                row(.comparison)
            }
            Section("Tests") {
                row(project.failureSection)
                row(.run)
            }
            Section("Library") {
                row(.library)
                // Only while there are orphans to clear away (or you're looking at them).
                if project.isListed(.orphaned) { row(.orphaned) }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ section: ProjectSection) -> some View {
        Label {
            HStack(spacing: DS.Space.s) {
                Text(project.shortTitle(of: section)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: DS.Space.xs)
                if let count = project.count(of: section), count > 0 {
                    SectionCount(count: count, color: Self.color(of: section))
                }
            }
        } icon: {
            Image(systemName: Self.symbol(of: section))
        }
        .tag(section)
        .help(project.title(of: section))
        // One VoiceOver stop per item, by its full name: "Changes vs develop, 7 changes". The count
        // is in the label: a sidebar row doesn't pass on an accessibility value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([project.title(of: section), project.countLabel(of: section)].compactMap { $0 }.joined(separator: ", "))
    }

    static func symbol(of section: ProjectSection) -> String {
        switch section {
        case .workingCopy: "square.and.pencil"
        case .comparison: "arrow.triangle.branch"
        case .lastRun: "testtube.2"
        case .ciJob: "server.rack"
        case .run: "terminal"
        case .library: "photo.stack"
        case .orphaned: "questionmark.square.dashed"
        }
    }

    /// Counts that need you carry their status colour, as a project's failing count does; the
    /// others are quantities.
    static func color(of section: ProjectSection) -> Color? {
        switch section {
        case .workingCopy: DS.Status.color(for: .uncommitted)
        case .lastRun, .ciJob: DS.Status.failed
        case .comparison, .run, .library, .orphaned: nil
        }
    }
}

/// A sidebar item's count, with a status dot when it is one.
struct SectionCount: View {
    var count: Int
    var color: Color?

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let color { Circle().fill(color).frame(width: DS.Status.dot, height: DS.Status.dot) }
            Text("\(count)").monospacedDigit()
        }
        .font(DS.Font.caption)
        .foregroundStyle(.secondary)
    }
}

/// The open project and its branch, at the top of the sidebar; a click lists the others.
struct ProjectSwitcher: View {
    @Environment(AppModel.self) private var model
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: DS.Space.s) {
                if let project = model.current {
                    ProjectMonogram(name: project.project.name)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(project.project.name).fontWeight(.semibold).lineLimit(1)
                        if let branch = project.branchLabel {
                            Text(branch).font(DS.Font.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                } else {
                    Text(model.projects.isEmpty ? "Add a Project" : "Choose a Project").fontWeight(.semibold)
                }
                Spacer(minLength: DS.Space.xs)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DS.Space.s)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(isPresented ? DS.Surface.selection : .clear))
        .padding(.horizontal, DS.Space.s)
        .padding(.bottom, DS.Space.xs)
        .help("Switch project (⌘K also finds projects and commands)")
        .accessibilityLabel(model.current.map { "Project: \($0.project.name)" } ?? "Choose a project")
        .accessibilityValue(model.current?.branchLabel ?? "")
        .accessibilityHint("Shows the other projects")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ProjectSwitcherList(close: { isPresented = false })
                .environment(model)
        }
    }
}

/// The projects to switch to: a search field, then pinned ones and the rest by name, and ways to
/// add more. Arrow keys and Return work from the field, as in the ⌘K palette.
struct ProjectSwitcherList: View {
    @Environment(AppModel.self) private var model
    var close: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var pinned: [Project] { model.projects.filter { model.isPinned($0) } }
    private var others: [Project] {
        model.projects.filter { !model.isPinned($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The projects in the order shown, which the highlight steps through.
    private var shown: [Project] {
        guard isSearching else { return pinned + others }
        return PaletteItem.ranked(projects: model.projects, commands: [], query: query).compactMap {
            if case .project(let project) = $0 { project } else { nil }
        }
    }
    static let rowHeight: CGFloat = 30

    var body: some View {
        let shown = shown
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .placeholder("Find a project", shown: query.isEmpty)
                    .accessibilityLabel("Find a project")
                    .focused($focused)
                    .onSubmit { open(at: highlighted, in: shown) }
                    .onKeyPress(.downArrow) { move(1, in: shown); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: shown); return .handled }
            }
            .fieldChrome()
            .padding(DS.Space.s)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if isSearching {
                            rows(shown, from: 0)
                        } else {
                            if !pinned.isEmpty {
                                header("Pinned")
                                rows(pinned, from: 0)
                            }
                            if !others.isEmpty || model.isScanning {
                                header(model.isScanning ? "Projects (scanning…)" : "Projects")
                                rows(others, from: pinned.count)
                            }
                        }
                        if shown.isEmpty {
                            Text(isSearching ? "No matching projects" : "No projects yet. Drop a repository on the window, or add one below.")
                                .font(DS.Font.secondary)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(DS.Space.s)
                        }
                    }
                    .padding(DS.Space.xs)
                }
                // As tall as its rows, up to twelve: no empty panel under three projects.
                .frame(height: min(CGFloat(max(shown.count, 1)) * Self.rowHeight + (isSearching ? 0 : 2 * Self.rowHeight),
                                   12 * Self.rowHeight) + DS.Space.s)
                .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                action("Add Project…") { model.addProjectFromPanel() }
                action("Add Scan Folder…") { model.addScanRootFromPanel() }
                if !model.store.settings.scanRoots.isEmpty {
                    action("Rescan Folders") { model.rescan() }
                }
            }
            .padding(DS.Space.xs)
        }
        .frame(width: 300)
        .onAppear {
            highlighted = shown.firstIndex { $0.path == model.selectedPath } ?? 0
            focused = true
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(DS.Font.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.s)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.xxs)
            .accessibilityAddTraits(.isHeader)
    }

    private func rows(_ projects: [Project], from offset: Int) -> some View {
        ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
            ProjectSwitcherRow(project: project, failing: model.failingCounts[project.path] ?? 0,
                               current: project.path == model.selectedPath, highlighted: offset + index == highlighted)
                .id(offset + index)
                .onTapGesture { open(project) }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open(project) }
                .help(project.path.abbreviatingWithTildeInPath)
                .contextMenu {
                    Button(model.isPinned(project) ? "Unpin" : "Pin") { model.togglePin(project) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                    Divider()
                    Button("Remove from List") { model.remove(project) }
                }
        }
    }

    /// One of the ways to add projects, under the list like a menu's last items. The popover closes
    /// first: each opens a panel.
    private func action(_ title: String, run: @escaping () -> Void) -> some View {
        Button {
            close()
            run()
        } label: {
            Text(title)
                .padding(.horizontal, DS.Space.s)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func move(_ delta: Int, in shown: [Project]) {
        guard !shown.isEmpty else { return }
        highlighted = (highlighted + delta + shown.count) % shown.count
        // Focus stays in the field, so VoiceOver wouldn't otherwise say where the highlight went.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: shown[highlighted].name])
    }

    private func open(at index: Int, in shown: [Project]) {
        guard shown.indices.contains(index) else { return }
        open(shown[index])
    }

    private func open(_ project: Project) {
        close()
        model.selectedPath = project.path
    }
}

/// A project in the switcher: monogram, name, and its failing count from the last run.
struct ProjectSwitcherRow: View {
    var project: Project
    var failing: Int
    var current: Bool
    var highlighted: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ProjectMonogram(name: project.name)
            Text(project.name).fontWeight(current ? .semibold : .regular).lineLimit(1)
            Spacer(minLength: DS.Space.s)
            // A failing count is status, so it carries the failed colour.
            if failing > 0 { FailingCount(count: failing) }
        }
        .padding(.horizontal, DS.Space.s)
        .frame(height: ProjectSwitcherList.rowHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(highlighted ? DS.Surface.selection : .clear))
        .contentShape(Rectangle())
        // One VoiceOver stop per project, its failing count included ("Chat, 4 failing").
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
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
        case .project(let project): Task { await model.open(path: project.path) }
        case .command(let command): command.run()
        }
    }

    private func close() {
        query = ""
        model.showQuickSwitcher = false
    }
}
