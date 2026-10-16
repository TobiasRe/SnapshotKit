import AppKit
import QuickLook
import SnapshotKitCore
import SwiftUI

/// Every snapshot in the project, grouped by test file, with a large inspector.
enum LibraryLayout: String {
    case list, grid
}

struct SnapshotsTab: View {
    @ObservedObject var project: ProjectModel
    @AppStorage("libraryLayout") private var layoutRaw = LibraryLayout.list.rawValue
    @State private var confirmRecordShown = false
    @State private var confirmTrashOrphans = false
    /// The snapshot shown in Quick Look (Space in the list, as in Finder).
    @State private var quickLookURL: URL?

    /// Above this many tests, re-recording what's shown asks first.
    static let confirmAbove = 10

    private var layout: LibraryLayout { LibraryLayout(rawValue: layoutRaw) ?? .list }

    var body: some View {
        switch layout {
        case .list: split
        case .grid:
            VStack(spacing: 0) {
                header
                Divider()
                SnapshotGrid(project: project) { file in
                    // Opening a tile shows it large in the list layout.
                    project.selectedSnapshotID = file.id
                    layoutRaw = LibraryLayout.list.rawValue
                }
                footer
            }
            .background(DS.Surface.content)
        }
    }

    private var split: some View {
        ListDetailSplit {
            VStack(spacing: 0) {
                header
                Divider()
                list
                    .frame(maxHeight: .infinity)
                footer
            }
            .background(DS.Surface.content)
            .frame(maxHeight: .infinity, alignment: .top)
        } detail: {
            Group {
                if let file = project.selectedSnapshot {
                    SnapshotDetail(project: project, file: file)
                } else if project.library?.files.isEmpty == true {
                    // A first run records the references (swift-snapshot-testing writes missing ones).
                    ContentUnavailableView {
                        Label("No Snapshots Yet", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Reference images appear here once a snapshot test records them. Run the tests to record the first ones.")
                    } actions: {
                        Button("Run Tests") { project.runTests() }
                            .primaryActionStyle()
                            .disabled(project.isRunning || project.environment == nil)
                    }
                } else {
                    ContentUnavailableView("No Snapshot Selected", systemImage: "photo.on.rectangle",
                                           description: Text("Select a snapshot to inspect it."))
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Search and view options, then the scope: the same two bars as the detail's header and info row.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneBar(height: DS.Bar.header) {
                SearchField(prompt: "Filter snapshots", text: $project.libraryFilter)
                    .help("Filter by module, suite, test or variant; every word must match")
                    // In the full-width grid a window-wide field reads as a page title.
                    .frame(maxWidth: 420)
                Spacer(minLength: 0)
                GlassIconMenu(title: "Sort By", symbol: "arrow.up.arrow.down", help: "Sort by name (grouped), size or most recently changed") {
                    Picker("Sort By", selection: $project.librarySort) {
                        ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                Picker("Layout", selection: $layoutRaw) {
                    Label("List", systemImage: "list.bullet").tag(LibraryLayout.list.rawValue)
                    Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid.rawValue)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .fixedSize()
                .help("Show snapshots as a list with a large preview, or as a grid")
                .accessibilityLabel("Layout")
            }
            PaneBar(height: DS.Bar.filters) {
                // Counts when they fit, then without, then a menu: never wraps or clips.
                ViewThatFits(in: .horizontal) {
                    scopePicker(counts: true).pickerStyle(.segmented)
                    scopePicker(counts: false).pickerStyle(.segmented)
                    Menu {
                        scopePicker(counts: true).pickerStyle(.inline)
                    } label: {
                        Label(scopeMenuTitle, systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .fixedSize()
                    .quietControl()
                }
                .labelsHidden()
                .controlSize(.small)
                // In the full-width grid, segments stretched across the window; keep them compact.
                .frame(maxWidth: 480, alignment: .leading)
                .accessibilityLabel("Show")
            }
            .padding(.bottom, DS.Space.xs)
        }
        .confirmationDialog("Move \(project.displayedSnapshots.count) orphaned snapshots to the Trash?", isPresented: $confirmTrashOrphans) {
            Button("Move to Trash", role: .destructive) { project.moveToTrash(project.displayedSnapshots) }
        } message: {
            Text("No test records or checks them any more. Commit the deletion to remove them from the repository.")
        }
        .confirmationDialog("Re-record \(testCount(project.displayedSnapshots)) tests?", isPresented: $confirmRecordShown) {
            Button("Re-record") { project.reRecord(project.displayedSnapshots, granularity: .tests) }
        } message: {
            Text("Their reference images are recorded again and then verified. You can review the result on the Changes tab before committing.")
        }
    }

    /// What the library holds, and the bulk action for what's shown.
    @ViewBuilder
    private var footer: some View {
        // Nothing to count or record yet: no footer of zeros.
        if let library = project.library, !library.files.isEmpty {
            PaneFooter {
                Text(LibraryStats(library).summary).lineLimit(1)
                Spacer(minLength: DS.Space.s)
                let shown = project.displayedSnapshots
                if project.libraryScope == .orphaned && !shown.isEmpty {
                    Button("Move \(shown.count) to Trash…") { confirmTrashOrphans = true }
                        .buttonStyle(.borderless)
                        .disabled(project.isRunning)
                        .help("Their tests no longer exist. Committed files stay recoverable through git, all of them from the Trash.")
                } else if !shown.isEmpty {
                    Button(shownTitle(shown)) {
                        if testCount(shown) > Self.confirmAbove { confirmRecordShown = true } else { project.reRecord(shown, granularity: .tests) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(shown.isEmpty || project.isRunning || project.environment == nil)
                    .help("Record the tests of every snapshot shown (filter first to narrow it down), then verify")
                }
            }
        }
    }

    private func scopePicker(counts: Bool) -> some View {
        Picker("Show", selection: $project.libraryScope) {
            ForEach(LibraryScope.allCases.filter { $0 != .orphaned || !project.orphanIDs.isEmpty || project.libraryScope == .orphaned }) { scope in
                let count = project.count(in: scope)
                Text(scope == .all || !counts || count == 0 ? scope.rawValue : "\(scope.rawValue) \(count)").tag(scope)
            }
        }
    }

    /// "Show: All", "Show: Failing 1": the narrow column's stand-in for the segmented control.
    private var scopeMenuTitle: String {
        let scope = project.libraryScope
        let count = project.count(in: scope)
        return scope == .all || count == 0 ? "Show: \(scope.rawValue)" : "Show: \(scope.rawValue) \(count)"
    }

    private func testCount(_ files: [SnapshotFile]) -> Int {
        Set(files.map { $0.module + "/" + $0.suite + "/" + $0.testName }).count
    }

    private func shownTitle(_ files: [SnapshotFile]) -> String {
        let all = files.count == (project.library?.files.count ?? 0)
        return all ? "Re-record All…" : "Re-record \(testCount(files)) Shown…"
    }

    @ViewBuilder
    private var list: some View {
        if project.library == nil && project.isLoadingLibrary {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let tree = project.displayedTree
            List(selection: $project.selectedSnapshotID) {
                if project.librarySort != .name {
                    Section {
                        ForEach(project.displayedSnapshots) { file in
                            SnapshotRow(file: file, status: project.status(of: file), load: project.snapshotLoader(for: file),
                                        detail: project.librarySort == .size ? .size : .modified,
                                        showVariant: project.showsVariant(file))
                                .tag(file.id)
                                .selectableRow(project.selectedSnapshotID == file.id)
                                .onDrag { NSItemProvider(contentsOf: project.project.url.appendingPathComponent(file.path)) ?? NSItemProvider() }
                                .contextMenu { SnapshotActions(project: project, file: file) }
                        }
                    } header: {
                        ListSectionHeader(title: project.librarySort == .size ? "Largest First" : "Most Recently Changed",
                                          count: project.displayedSnapshots.count)
                    }
                } else {
                ForEach(tree) { module in
                    ForEach(module.suites) { suite in
                        Section {
                            ForEach(suite.tests) { test in
                                ForEach(test.files) { file in
                                    SnapshotRow(file: file, status: project.status(of: file), load: project.snapshotLoader(for: file),
                                                showVariant: project.showsVariant(file))
                                        .tag(file.id)
                                        .selectableRow(project.selectedSnapshotID == file.id)
                                        // Drag a snapshot out, e.g. into a pull request comment.
                                        .onDrag { NSItemProvider(contentsOf: project.project.url.appendingPathComponent(file.path)) ?? NSItemProvider() }
                                        .contextMenu { SnapshotActions(project: project, file: file) }
                                }
                            }
                        } header: {
                            ListSectionHeader(title: tree.count > 1 ? "\(module.name) › \(suite.name)" : suite.name, count: suite.fileCount)
                        }
                    }
                }
                }
            }
            .onKeyPress(.space) {
                guard let file = project.selectedSnapshot else { return .ignored }
                quickLookURL = project.project.url.appendingPathComponent(file.path)
                return .handled
            }
            .quickLookPreview($quickLookURL)
            .overlay {
                if tree.isEmpty && !project.libraryFilter.isEmpty {
                    ContentUnavailableView.search(text: project.libraryFilter)
                } else if tree.isEmpty && project.libraryScope != .all {
                    ContentUnavailableView("Nothing \(project.libraryScope.rawValue)", systemImage: "checkmark.circle",
                                           description: Text("No snapshot is \(project.libraryScope.rawValue.lowercased()) right now."))
                }
            }
        }
    }
}

/// "312 snapshots · 148 tests · 4 modules · 48.2 MB"
struct LibraryStats {
    var library: SnapshotLibrary
    init(_ library: SnapshotLibrary) { self.library = library }

    var summary: String {
        let modules = Set(library.files.map(\.module)).count
        let size = SnapshotLibrary.formatSize(library.totalBytes)
        return "\(library.files.count) snapshot\(library.files.count == 1 ? "" : "s") · \(library.testCount) test\(library.testCount == 1 ? "" : "s") · "
            + "\(modules) module\(modules == 1 ? "" : "s") · \(size)"
    }
}

struct SnapshotRow: View {
    /// Extra information for a flat, sorted list, where the suite header is missing.
    enum Detail { case none, size, modified }
    var file: SnapshotFile
    var status = SnapshotStatus()
    var load: @Sendable () -> Data?
    var detail = Detail.none
    /// Whether the variant says anything (see `ProjectModel.showsVariant`).
    var showVariant = true

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Thumbnail(id: "snapshot:\(file.path)#\(file.byteSize)", load: load)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(file.testName).fontWeight(.medium).lineLimit(1)
                if detail != .none {
                    Text(file.suite).font(DS.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: DS.Space.xs) {
                    if showVariant && !file.variant.isEmpty {
                        Text(file.variant).font(DS.Font.code).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if file.state != .clean { SnapshotStateChip(state: file.state) }
                    if status.orphaned { Chip(text: "Orphaned", color: DS.Status.neutral).help("Its test no longer exists") }
                }
            }
            Spacer(minLength: DS.Space.s)
            StatusMarks(status: status)
            switch detail {
            case .size:
                Text(SnapshotLibrary.formatSize(file.byteSize))
                    .font(DS.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
            case .modified:
                if let modified = file.modified {
                    Text(modified, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(DS.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            case .none:
                EmptyView()
            }
        }
        .padding(.vertical, DS.Space.xxs)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.testName) \(file.variant), in \(file.suite)"
                            + (file.state == .clean ? "" : ", \(SnapshotStateChip.label(file.state))")
                            + (status.failureID == nil ? "" : ", failing")
                            + (status.change.map { ", \($0.label.lowercased()) change" } ?? ""))
    }
}

/// Small marks at the end of a row: failing in the last run, changed against the base branch.
struct StatusMarks: View {
    var status: SnapshotStatus

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if status.failureID != nil {
                Image(systemName: status.verdict == .flaky ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                    .foregroundStyle(status.verdict == .flaky ? DS.Status.flaky : DS.Status.failed)
                    .help(status.verdict == .flaky ? "Flaky: failed in some runs" : "Its test failed in the last run")
            }
            if let change = status.change {
                KindBadge(kind: change, style: .dot)
                    .help("\(change.label) change against the base branch")
            }
        }
        .accessibilityHidden(true)
    }
}

struct SnapshotStateChip: View {
    var state: SnapshotFile.State

    static func label(_ state: SnapshotFile.State) -> String {
        switch state {
        case .clean: "Committed"
        case .modified: "Modified"
        case .untracked: "New"
        }
    }

    var body: some View {
        Chip(text: Self.label(state), color: state == .untracked ? DS.Status.color(for: .new) : DS.Status.color(for: .uncommitted))
    }
}

/// Actions on one snapshot, for the context menu and the detail header.
struct SnapshotActions: View {
    @ObservedObject var project: ProjectModel
    var file: SnapshotFile

    var body: some View {
        let url = project.project.url.appendingPathComponent(file.path)
        let disabled = project.isRunning || project.environment == nil || project.orphanIDs.contains(file.id)
        Button("Re-record \(file.testName)") { project.reRecord([file], granularity: .tests) }
            .disabled(disabled)
        Button("Re-record Suite \(file.suite)") { project.reRecord([file], granularity: .suites) }
            .disabled(disabled)
        Divider()
        Button("Open in Default App") { NSWorkspace.shared.open(url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        Button("Copy Image") {
            if let data = try? Data(contentsOf: url) { Clipboard.copyImage(data) }
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        }
    }
}

/// Where the image area starts in a snapshot's detail; it must not move between snapshots.
struct SnapshotCanvasTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One snapshot, large: zoom, pan and read pixels, with what it is and where it lives.
struct SnapshotDetail: View {
    @ObservedObject var project: ProjectModel
    var file: SnapshotFile
    @State private var versions: [SnapshotVersion]?
    private var comparing: SnapshotVersion? {
        if case .version(let v) = project.comparison { v } else { nil }
    }
    private var comparedVariant: SnapshotFile? {
        if case .variant(let f) = project.comparison, f.id != file.id, f.module == file.module, f.suite == file.suite,
           f.testName == file.testName { f } else { nil }
    }
    @Environment(\.locale) private var locale

    /// "Oct 12, 2026" in the view's locale (not the process's), like `Text(date, format:)`.
    private func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }

    var body: some View {
        let status = project.status(of: file)
        VStack(spacing: 0) {
            let shown = project.displayedSnapshots.map(\.id)
            DetailHeader(title: project.showsVariant(file) ? "\(file.testName) · \(file.variant)" : file.testName,
                         subtitle: Breadcrumb.of(module: file.module, suite: file.suite), path: file.path,
                         position: shown.firstIndex(of: file.id).map { ($0 + 1, shown.count) },
                         step: { project.selectAdjacent($0) }) {
                HStack(spacing: DS.Space.s) {
                    statusChips(status)
                    GlassSplitButton(title: "Re-record", symbol: "camera",
                                     help: status.orphaned ? "Its test no longer exists"
                                         : "Record this test's snapshots again, then check that it passes (⇧⌘R)") {
                        project.reRecord([file], granularity: .tests)
                    } menu: {
                        Button("Re-record Test") { project.reRecord([file], granularity: .tests) }
                        Button("Re-record Suite \(file.suite)") { project.reRecord([file], granularity: .suites) }
                    }
                    .disabled(project.isRunning || project.environment == nil || status.orphaned)
                    GlassIconMenu(title: "Snapshot Actions", symbol: "ellipsis", help: "Open, reveal or copy the path of this snapshot") {
                        SnapshotActions(project: project, file: file)
                        if status.orphaned {
                            Divider()
                            Button("Move to Trash") { project.moveToTrash([file]) }
                        }
                    }
                }
                .controlSize(.small)
            }
            infoRow
            Divider()
                .background(GeometryReader { geo in
                    Color.clear.preference(key: SnapshotCanvasTopKey.self, value: geo.frame(in: .global).maxY)
                })
            if let other = comparedVariant {
                CompareView(load: { [a = project.snapshotLoader(for: other), b = project.snapshotLoader(for: file)] in (a(), b()) },
                            beforeLabel: other.variant, afterLabel: file.variant,
                            identity: "\(other.path)#\(other.byteSize)~\(file.path)#\(file.byteSize)")
            } else if let comparing {
                let before = project.versionLoader(for: file, commit: comparing.commit), after = project.snapshotLoader(for: file)
                CompareView(load: { (before(), after()) },
                            beforeLabel: "\(comparing.shortCommit) · \(day(comparing.date))",
                            afterLabel: file.state == .clean ? "Current" : "Working tree",
                            identity: "\(file.path)#\(file.byteSize)@\(comparing.commit)")
            } else {
                SnapshotViewer(load: project.snapshotLoader(for: file), identity: "\(file.path)#\(file.byteSize)",
                               fileSize: file.byteSize)
            }
        }
        .task(id: file.id) {
            versions = nil
            versions = await project.history(of: file)
        }
    }

    /// Failing, changed or orphaned, as small chips in the header (which keeps its height);
    /// failing and changed open the snapshot in the view that explains it.
    @ViewBuilder
    private func statusChips(_ status: SnapshotStatus) -> some View {
        if let id = status.failureID {
            Button { project.showFailure(id) } label: {
                Chip(text: status.verdict == .flaky ? "Flaky" : "Failing", color: status.verdict == .flaky ? DS.Status.flaky : DS.Status.failed)
            }
            .buttonStyle(.plain)
            .help("Its test failed in the last run. Click to compare with the actual image.")
            .accessibilityLabel(status.verdict == .flaky ? "Flaky, compare with actual" : "Failing, compare with actual")
        }
        // One chip for what changed: an uncommitted file says New or Modified, a committed change
        // says Changed; either opens the change for review when there is one.
        if let change = status.change {
            Button { project.showChange(path: file.path) } label: {
                if file.state == .clean {
                    Chip(text: "Changed", color: DS.Status.color(for: change))
                } else {
                    SnapshotStateChip(state: file.state)
                }
            }
            .buttonStyle(.plain)
            .help("\(change.label) change against \(project.baseBranch ?? "the base branch"). Click to review it.")
            .accessibilityLabel("\(file.state == .clean ? "Changed" : SnapshotStateChip.label(file.state)) against the base branch, review change")
        } else if file.state != .clean {
            SnapshotStateChip(state: file.state)
        }
        if status.orphaned {
            Chip(text: "Orphaned", color: DS.Status.neutral)
                .help("No test named \(file.testName) in \(file.suite).swift any more. Move it to the Trash from the actions menu.")
        }
    }

    /// History, the test's variants and what to compare with, in one row of fixed height that is
    /// always there; while the history loads it says so instead of collapsing.
    private var infoRow: some View {
        let variants = project.variants(of: file)
        return DetailInfoRow {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).accessibilityHidden(true)
            historyText
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Space.s)
            if variants.count > 1 {
                Picker("Variant", selection: Binding(get: { file.id }, set: { project.selectedSnapshotID = $0 })) {
                    ForEach(variants) { Text($0.variant.isEmpty ? "default" : $0.variant).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("This test's variants")
                .accessibilityLabel("Variant")
            }
            compareMenu(variants: variants)
        }
        .padding(.bottom, DS.Space.xs)
        .background(DS.Surface.content)
    }

    @ViewBuilder
    private var historyText: some View {
        if let versions {
            if let last = versions.first {
                Text("\(versions.count) version\(versions.count == 1 ? "" : "s") · last committed \(day(last.date)) by \(last.author) in ")
                    + Text(last.shortCommit).font(DS.Font.code)
                    + Text(" “\(last.subject)”")
            } else {
                Text(file.state == .untracked ? "Not committed yet" : "No committed versions")
            }
        } else {
            Text("Reading history…")
        }
    }

    private func compareMenu(variants: [SnapshotFile]) -> some View {
        let others = variants.filter { $0.id != file.id }
        return Menu {
            Button("Nothing (Show Current Only)") { project.comparison = nil }
            if !others.isEmpty {
                Section("Variants") {
                    ForEach(others) { other in
                        Button(other.variant) { project.comparison = .variant(other) }
                    }
                }
            }
            if let versions, !versions.isEmpty {
                Section("Committed Versions") {
                    ForEach(versions) { version in
                        Button("\(version.shortCommit) · \(day(version.date)) · \(version.subject)") {
                            project.comparison = .version(version)
                        }
                    }
                }
            }
        } label: {
            Text(comparedVariant.map { "Comparing with \($0.variant)" }
                 ?? comparing.map { "Comparing with \($0.shortCommit)" } ?? "Compare with…")
        }
        .fixedSize()
        .quietControl()
        .disabled(others.isEmpty && (versions ?? []).isEmpty)
        .help("Compare this snapshot with another variant of its test or an earlier committed version")
        .accessibilityLabel("Compare With")
    }
}

/// A single image with the compare view's zoom, pan and pixel readout.
struct SnapshotViewer: View {
    @EnvironmentObject private var app: AppModel
    var load: @Sendable () -> Data?
    var identity: String
    var fileSize: Int

    @State private var image: PixelImage?
    @State private var nsImage: NSImage?
    @State private var probe: PixelProbe?

    init(load: @escaping @Sendable () -> Data?, identity: String, fileSize: Int) {
        self.load = load
        self.identity = identity
        self.fileSize = fileSize
        let cached = SnapshotImageCache.shared.object(forKey: identity as NSString)
        _image = State(initialValue: cached?.pixels)
        _nsImage = State(initialValue: cached?.image)
    }

    var body: some View {
        let size = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        ZStack(alignment: .bottom) {
            Group {
                if nsImage != nil {
                    ZoomableImage(image: nsImage, pixelSize: size, viewport: app.viewport)
                        .overlay(ZoomPanSurface(viewport: $app.viewport, onHover: { hover($0, size: size) }))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CheckerboardBackground())

            VStack(spacing: DS.Space.s) {
                if let probe, let color = image?.color(x: probe.x, y: probe.y) {
                    HStack(spacing: DS.Space.m) {
                        Text("x \(probe.x)  y \(probe.y)").foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(.sRGB, red: Double(color.r) / 255, green: Double(color.g) / 255,
                                        blue: Double(color.b) / 255, opacity: Double(color.a) / 255))
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color(nsColor: .separatorColor)))
                            .frame(width: 10, height: 10)
                        Text(color.hex)
                    }
                    .font(DS.Font.code.monospacedDigit())
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, DS.Space.s - 2)
                    .floatingGlassCapsule()
                    .fixedSize()
                }
                bar(size: size)
            }
            .padding(.bottom, DS.Space.m)
        }
        .clipped()
        .task(id: identity) {
            if let cached = SnapshotImageCache.shared.object(forKey: identity as NSString) {
                image = cached.pixels
                nsImage = cached.image
                return
            }
            let load = load
            let decoded = await Task.detached { SnapshotImageCache.Entry(data: load()) }.value
            if let decoded { SnapshotImageCache.store(decoded, for: identity) }
            image = decoded?.pixels
            nsImage = decoded?.image
        }
    }

    private func bar(size: CGSize) -> some View {
        GlassGroup {
            HStack(spacing: DS.Space.m) {
                if size.width > 0 {
                    Text("\(Int(size.width))×\(Int(size.height))")
                        .font(DS.Font.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(SnapshotLibrary.formatSize(fileSize))
                    .font(DS.Font.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                ControlGroup {
                    Button { withAnimation(DS.motion) { app.viewport.zoomOut() } } label: { Image(systemName: "minus") }
                        .help("Zoom out (⌘−)")
                        .accessibilityLabel("Zoom Out")
                    Button(abs(app.viewport.scale - 1) < 0.01 ? "Fit" : String(format: "%.1f×", app.viewport.scale)) {
                        withAnimation(DS.motion) { app.viewport.reset() }
                    }
                    .monospacedDigit()
                    .help("Fit (⌘0)")
                    .accessibilityLabel("Zoom to Fit")
                    Button { withAnimation(DS.motion) { app.viewport.zoomIn() } } label: { Image(systemName: "plus") }
                        .help("Zoom in (⌘=)")
                        .accessibilityLabel("Zoom In")
                }
                .controlGroupStyle(.navigation)
                .fixedSize()
            }
            .controlSize(.small)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s - 2)
            .floatingGlassCapsule()
            .fixedSize()
        }
    }

    private func hover(_ location: (point: CGPoint, canvas: CGSize)?, size: CGSize) {
        guard let location, size.width > 0,
              let p = app.viewport.pixel(at: location.point, imageSize: size, canvas: location.canvas) else {
            if probe != nil { probe = nil }
            return
        }
        let next = PixelProbe(x: p.x, y: p.y)
        if next != probe { probe = next }
    }
}

/// Decoded snapshots keyed by path and size, so revisiting one is instant. Bounded by memory.
enum SnapshotImageCache {
    final class Entry: @unchecked Sendable {
        let pixels: PixelImage
        let image: NSImage
        init?(data: Data?) {
            guard let pixels = data.flatMap(PixelImage.init(data:)), let cg = pixels.cgImage else { return nil }
            self.pixels = pixels
            image = NSImage(cgImage: cg, size: NSSize(width: pixels.width, height: pixels.height))
        }
    }

    static let shared: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 200 * 1024 * 1024
        return cache
    }()

    static func store(_ entry: Entry, for identity: String) {
        shared.setObject(entry, forKey: identity as NSString, cost: entry.pixels.width * entry.pixels.height * 8)
    }
}

/// A contact sheet of the library: every snapshot as a tile, grouped by test file.
struct SnapshotGrid: View {
    @ObservedObject var project: ProjectModel
    var open: (SnapshotFile) -> Void

    static let tile = CGSize(width: 180, height: 124)

    var body: some View {
        let tree = project.displayedTree
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.l, pinnedViews: [.sectionHeaders]) {
                if project.librarySort != .name {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tile.width + 2 * DS.Space.s), spacing: DS.Space.xs, alignment: .top)],
                              alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(project.displayedSnapshots) { tile($0) }
                    }
                    .padding(.horizontal, DS.Space.s)
                }
                ForEach(project.librarySort == .name ? tree : []) { module in
                    ForEach(module.suites) { suite in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tile.width + 2 * DS.Space.s), spacing: DS.Space.xs, alignment: .top)],
                                      alignment: .leading, spacing: DS.Space.xs) {
                                ForEach(suite.tests.flatMap(\.files)) { file in
                                    tile(file)
                                }
                            }
                            // Tiles bring their own padding (the selection fill); the grid edge lines up
                            // with the section header's text.
                            .padding(.horizontal, DS.Space.s)
                        } header: {
                            ListSectionHeader(title: tree.count > 1 ? "\(module.name) › \(suite.name)" : suite.name, count: suite.fileCount)
                            .padding(.horizontal, DS.Space.l)
                            .padding(.vertical, DS.Space.s)
                            .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                }
            }
            .padding(.vertical, DS.Space.m)
        }
        .overlay {
            if tree.isEmpty {
                ContentUnavailableView("No Snapshots", systemImage: "photo.on.rectangle",
                                       description: Text(project.libraryFilter.isEmpty ? "Nothing matches this scope." : "Nothing matches the filter."))
            }
        }
    }

    private func tile(_ file: SnapshotFile) -> some View {
        let selected = project.selectedSnapshotID == file.id
        let status = project.status(of: file)
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            Thumbnail(id: "snapshot:\(file.path)#\(file.byteSize)", size: Self.tile, load: project.snapshotLoader(for: file))
                .overlay(alignment: .topTrailing) {
                    if status.failureID != nil || status.change != nil {
                        StatusMarks(status: status)
                            .padding(.horizontal, DS.Space.xs)
                            .padding(.vertical, DS.Space.xxs)
                            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.9)))
                            .padding(DS.Space.xs)
                    }
                }
            HStack(spacing: DS.Space.xs) {
                Text(file.testName).font(DS.Font.secondary).fontWeight(.medium).lineLimit(1)
                if file.state != .clean { SnapshotStateChip(state: file.state) }
            }
            if project.showsVariant(file) {
                Text(file.variant).font(DS.Font.code).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: Self.tile.width, alignment: .leading)
        // Selected like a list row: a quiet fill behind the whole tile, not an accent frame.
        .padding(DS.Space.s)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
            .fill(selected ? DS.Surface.selection : .clear))
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: project.project.url.appendingPathComponent(file.path)) ?? NSItemProvider() }
        .onTapGesture(count: 2) { open(file) }
        .onTapGesture { project.selectedSnapshotID = file.id }
        .contextMenu {
            Button("Show Large") { open(file) }
            Divider()
            SnapshotActions(project: project, file: file)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.testName) \(file.variant)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { open(file) }
    }
}
