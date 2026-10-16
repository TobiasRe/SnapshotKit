import AppKit
import SnapshotKitCore
import SwiftUI

/// Every snapshot in the project, grouped by test file, with a large inspector.
enum LibraryLayout: String {
    case list, grid
}

struct SnapshotsTab: View {
    @ObservedObject var project: ProjectModel
    @AppStorage("libraryLayout") private var layoutRaw = LibraryLayout.list.rawValue

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
            }
        }
    }

    private var split: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                list
                    .frame(maxHeight: .infinity)
            }
            .frame(minWidth: 280, idealWidth: 330, maxWidth: 460, maxHeight: .infinity, alignment: .top)

            Group {
                if let file = project.selectedSnapshot {
                    SnapshotDetail(project: project, file: file)
                } else if project.library?.files.isEmpty == true {
                    ContentUnavailableView("No Snapshots Yet", systemImage: "photo.on.rectangle.angled",
                                           description: Text("Reference images appear here once a snapshot test records them."))
                } else {
                    ContentUnavailableView("No Snapshot Selected", systemImage: "photo.on.rectangle",
                                           description: Text("Select a snapshot to inspect it."))
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                SearchField(prompt: "Filter modules, suites and tests", text: $project.libraryFilter)
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
            Picker("Show", selection: $project.libraryScope) {
                ForEach(LibraryScope.allCases) { scope in
                    let n = project.count(in: scope)
                    Text(scope == .all ? scope.rawValue : "\(scope.rawValue) \(n)").tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Show")
            if let library = project.library {
                Text(LibraryStats(library).summary)
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(DS.Space.m)
    }

    @ViewBuilder
    private var list: some View {
        if project.library == nil && project.isLoadingLibrary {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let tree = SnapshotLibrary.tree(project.filteredSnapshots)
            List(selection: $project.selectedSnapshotID) {
                ForEach(tree) { module in
                    ForEach(module.suites) { suite in
                        Section {
                            ForEach(suite.tests) { test in
                                ForEach(test.files) { file in
                                    SnapshotRow(file: file, status: project.status(of: file), load: project.snapshotLoader(for: file))
                                        .tag(file.id)
                                        .contextMenu { SnapshotActions(project: project, file: file) }
                                }
                            }
                        } header: {
                            HStack {
                                Text(tree.count > 1 ? "\(module.name) › \(suite.name)" : suite.name)
                                Spacer()
                                Text("\(suite.fileCount)").monospacedDigit()
                            }
                        }
                    }
                }
            }
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
        let size = ByteCountFormatter.string(fromByteCount: Int64(library.totalBytes), countStyle: .file)
        return "\(library.files.count) snapshot\(library.files.count == 1 ? "" : "s") · \(library.testCount) tests · "
            + "\(modules) module\(modules == 1 ? "" : "s") · \(size)"
    }
}

struct SnapshotRow: View {
    var file: SnapshotFile
    var status = SnapshotStatus()
    var load: @Sendable () -> Data?

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Thumbnail(id: "snapshot:\(file.path)#\(file.byteSize)", load: load)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(file.testName).lineLimit(1)
                HStack(spacing: DS.Space.xs) {
                    if !file.variant.isEmpty {
                        Text(file.variant).font(DS.Font.code).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if file.state != .clean { SnapshotStateChip(state: file.state) }
                }
            }
            Spacer(minLength: DS.Space.s)
            StatusMarks(status: status)
        }
        .padding(.vertical, DS.Space.xxs)
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
        Button("Open in Default App") { NSWorkspace.shared.open(url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        }
    }
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
        VStack(spacing: 0) {
            DetailHeader(title: file.variant.isEmpty ? file.testName : "\(file.testName) · \(file.variant)", subtitle: file.path) {
                HStack(spacing: DS.Space.s) {
                    if file.state != .clean { SnapshotStateChip(state: file.state) }
                    Menu {
                        SnapshotActions(project: project, file: file)
                    } label: {
                        Label("Snapshot Actions", systemImage: "ellipsis")
                    }
                    .labelStyle(.iconOnly)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Open, reveal or copy the path of this snapshot")
                    .accessibilityLabel("Snapshot Actions")
                }
            }
            let status = project.status(of: file)
            if status.failureID != nil || status.change != nil {
                HStack(spacing: DS.Space.m) {
                    if let id = status.failureID {
                        Label(status.verdict == .flaky ? "Flaky" : "Failed in the last run",
                              systemImage: status.verdict == .flaky ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                            .foregroundStyle(DS.Status.text(status.verdict == .flaky ? DS.Status.flaky : DS.Status.failed))
                            .lineLimit(1)
                            .fixedSize()
                        Button("Compare with Actual") { project.showFailure(id) }
                            .controlSize(.small)
                    }
                    if let change = status.change {
                        Label("\(change.label) vs \(project.baseBranch ?? "base")", systemImage: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        Button("Review Change") { project.showChange(path: file.path) }
                            .controlSize(.small)
                    }
                    Spacer()
                }
                .font(DS.Font.secondary)
                .padding(.horizontal, DS.Space.l)
                .padding(.bottom, DS.Space.m)
            }
            historyBar
            let variants = project.variants(of: file)
            if variants.count > 1 { variantBar(variants) }
            Divider()
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
                               caption: "\(file.module) › \(file.suite)", fileSize: file.byteSize)
            }
        }
        .task(id: file.id) {
            versions = nil
            versions = await project.history(of: file)
        }
    }

    /// The test's variants as a row of choices: pick one to show it.
    private func variantBar(_ variants: [SnapshotFile]) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "square.stack").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Variants").foregroundStyle(.secondary)
            Picker("Variant", selection: Binding(get: { file.id }, set: { project.selectedSnapshotID = $0 })) {
                ForEach(variants) { Text($0.variant.isEmpty ? "default" : $0.variant).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .accessibilityLabel("Variant")
            Spacer()
        }
        .font(DS.Font.secondary)
        .padding(.horizontal, DS.Space.l)
        .padding(.bottom, DS.Space.m)
    }

    /// "3 versions · last changed Oct 12 by Ana in 3f1c2a9 “Re-record cards”", and what to compare with.
    @ViewBuilder
    private var historyBar: some View {
        if let versions {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).accessibilityHidden(true)
                Group {
                    if let last = versions.first {
                        Text("\(versions.count) version\(versions.count == 1 ? "" : "s") · last committed \(day(last.date)) by \(last.author) in ")
                            + Text(last.shortCommit).font(DS.Font.code)
                            + Text(" “\(last.subject)”")
                    } else {
                        Text(file.state == .untracked ? "Not committed yet" : "No committed versions")
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: DS.Space.s)
                if !versions.isEmpty || project.variants(of: file).count > 1 {
                    Menu {
                        Button("Nothing (Show Current Only)") { project.comparison = nil }
                        let others = project.variants(of: file).filter { $0.id != file.id }
                        if !others.isEmpty {
                            Section("Variants") {
                                ForEach(others) { other in
                                    Button(other.variant) { project.comparison = .variant(other) }
                                }
                            }
                        }
                        Divider()
                        ForEach(versions) { version in
                            Button("\(version.shortCommit) · \(day(version.date)) · \(version.subject)") {
                                project.comparison = .version(version)
                            }
                        }
                    } label: {
                        Text(comparedVariant.map { "Comparing with \($0.variant)" }
                             ?? comparing.map { "Comparing with \($0.shortCommit)" } ?? "Compare with…")
                    }
                    .fixedSize()
                    .controlSize(.small)
                    .help("Compare this snapshot with another variant of its test or an earlier committed version")
                    .accessibilityLabel("Compare With")
                }
            }
            .font(DS.Font.secondary)
            .padding(.horizontal, DS.Space.l)
            .padding(.bottom, DS.Space.m)
        }
    }
}

/// A single image with the compare view's zoom, pan and pixel readout.
struct SnapshotViewer: View {
    @EnvironmentObject private var app: AppModel
    var load: @Sendable () -> Data?
    var identity: String
    var caption: String
    var fileSize: Int

    @State private var image: PixelImage?
    @State private var nsImage: NSImage?
    @State private var probe: PixelProbe?

    init(load: @escaping @Sendable () -> Data?, identity: String, caption: String, fileSize: Int) {
        self.load = load
        self.identity = identity
        self.caption = caption
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
            .overlay(alignment: .topLeading) {
                Text(caption)
                    .font(DS.Font.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xs)
                    .floatingGlassCapsule()
                    .padding(DS.Space.m)
            }

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
                Text(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
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
        let tree = SnapshotLibrary.tree(project.filteredSnapshots)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.l, pinnedViews: [.sectionHeaders]) {
                ForEach(tree) { module in
                    ForEach(module.suites) { suite in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tile.width), spacing: DS.Space.l)],
                                      alignment: .leading, spacing: DS.Space.l) {
                                ForEach(suite.tests.flatMap(\.files)) { file in
                                    tile(file)
                                }
                            }
                            .padding(.horizontal, DS.Space.l)
                        } header: {
                            HStack {
                                Text(tree.count > 1 ? "\(module.name) › \(suite.name)" : suite.name)
                                    .font(DS.Font.heading)
                                Spacer()
                                Text("\(suite.fileCount)").monospacedDigit().foregroundStyle(.secondary)
                            }
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
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
            HStack(spacing: DS.Space.xs) {
                Text(file.testName).font(DS.Font.secondary).lineLimit(1)
                if file.state != .clean { SnapshotStateChip(state: file.state) }
            }
            if !file.variant.isEmpty {
                Text(file.variant).font(DS.Font.code).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: Self.tile.width, alignment: .leading)
        .contentShape(Rectangle())
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
