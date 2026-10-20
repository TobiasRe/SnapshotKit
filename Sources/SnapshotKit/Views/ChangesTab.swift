import AppKit
import QuickLook
import SnapshotKitCore
import SwiftUI

struct ChangesTab: View {
    @Bindable var project: ProjectModel
    @State private var pendingDiscard: SnapshotChange?
    /// Changes waiting for the Revert confirmation: one from its menu, or everything shown.
    @State private var pendingRevert: [SnapshotChange] = []
    @State private var confirmDiscardInvisible = false
    /// The changed snapshot shown in Quick Look (Space in the list, as in Finder).
    @State private var quickLookURL: URL?

    var body: some View {
        ListDetailSplit {
            VStack(spacing: 0) {
                filterBar
                Divider()
                if !project.invisibleUncommitted.isEmpty { invisibleNotice }
                list
                    .frame(maxHeight: .infinity)
                footer
            }
            .background(DS.Surface.content)
            .frame(maxHeight: .infinity, alignment: .top)
        } detail: {
            Group {
                if let change = project.selectedChange {
                    VStack(spacing: 0) {
                        let shown = project.displayedChanges.map(\.id)
                        DetailHeader(title: project.showsVariant(change.file) ? "\(change.file.testName) · \(change.file.variant)" : change.file.testName,
                                     subtitle: Breadcrumb.of(module: SnapshotModules.module(forSnapshotPath: change.path), suite: change.suite),
                                     path: change.path,
                                     position: shown.firstIndex(of: change.id).map { ($0 + 1, shown.count) },
                                     step: { project.selectAdjacent($0) }) {
                            HStack(spacing: DS.Space.s) {
                                Chip(text: change.kind.label, color: DS.Status.color(for: change.kind))
                                let viewed = project.viewedChanges.contains(change.id)
                                Button { project.setViewed(!viewed, for: change) } label: {
                                    Label("Viewed", systemImage: viewed ? "checkmark.circle.fill" : "circle")
                                }
                                .foregroundStyle(viewed ? .primary : .secondary)
                                .fixedSize()
                                .quietControl()
                                .help("Mark as reviewed and go to the next snapshot (V in the list)")
                                .accessibilityLabel("Viewed")
                                .accessibilityValue(viewed ? "On" : "Off")
                                .accessibilityAddTraits(viewed ? .isSelected : [])
                                GlassIconMenu(title: "Snapshot Actions", symbol: "ellipsis", help: "Open, reveal or discard this snapshot") {
                                    actions(for: change)
                                }
                            }
                            .controlSize(.small)
                        }
                        infoRow(change)
                        Divider()
                        CompareView(load: project.imageLoader(for: change),
                                    beforeLabel: "\(project.changeSet?.baseBranch ?? "Base") · \(project.diffBase.label.lowercased())",
                                    afterLabel: change.kind == .uncommitted || change.kind == .new ? "Working tree" : "This branch",
                                    identity: change.id + "#" + (project.changeSet?.baseCommit ?? "") + "#\(change.kind)",
                                    beforeMissing: "Added on this branch.",
                                    afterMissing: "Deleted on this branch.")
                    }
                } else if project.changesError != nil {
                    ContentUnavailableView("Choose a Base Branch", systemImage: "arrow.triangle.branch",
                                           description: Text("Pick the branch your merge requests target from the base branch menu above the list."))
                } else if !project.displayedChanges.isEmpty {
                    // Only when there is something to select; an empty list (nothing changed, all
                    // viewed and hidden, nothing matching) says why on its own.
                    ContentUnavailableView("No Snapshot Selected", systemImage: "photo.on.rectangle",
                                           description: Text("Select a changed snapshot to compare it with \(project.baseBranch ?? "the base branch")."))
                } else {
                    DS.Surface.content
                }
            }
            .frame(minWidth: DS.Pane.minDetailWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Discard \(project.invisibleUncommitted.count) re-recorded snapshots with no visible change?",
                            isPresented: $confirmDiscardInvisible) {
            Button("Discard", role: .destructive) { project.discardInvisibleChanges() }
        } message: {
            Text("They are restored to the committed version. Only uncommitted snapshots that look the same as before are touched.")
        }
        .confirmationDialog(
            "Discard the change to \(pendingDiscard?.fileName ?? "this snapshot")?",
            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
            presenting: pendingDiscard
        ) { change in
            Button("Discard", role: .destructive) { project.discard(change) }
        } message: { change in
            Text(change.kind == .new
                 ? "The new, untracked file is deleted."
                 : "The snapshot is restored to the committed version. Uncommitted edits to it are lost.")
        }
        .confirmationDialog(
            revertTitle,
            isPresented: Binding(get: { !pendingRevert.isEmpty }, set: { if !$0 { pendingRevert = [] } })
        ) {
            Button("Revert", role: .destructive) { project.revertToBase(pendingRevert) }
        } message: {
            Text("Modified snapshots get \(baseName)'s image, new ones are removed and deleted ones come back. "
                 + "Only the working tree changes: review the result and commit it.")
        }
    }

    private var baseName: String { project.changeSet?.baseBranch ?? "the base branch" }

    private var revertTitle: String {
        pendingRevert.count == 1
            ? "Revert \(pendingRevert[0].fileName) to \(baseName)?"
            : "Revert \(pendingRevert.count) snapshots to \(baseName)?"
    }

    @ViewBuilder
    private func actions(for change: SnapshotChange) -> some View {
        if change.kind != .deleted {
            Button("Re-record \(change.file.testName)") { project.reRecord([change.file], granularity: .tests) }
                .disabled(project.isRunning || project.environment == nil || project.orphanIDs.contains(change.id))
            Button("Show in Library") { project.showInLibrary(path: change.path) }
                .disabled(!project.isInLibrary(change.path))
            Button("Open Test in Xcode") { project.openTestInXcode(change.file) }
            Divider()
            Button("Open in Default App") { NSWorkspace.shared.open(project.fileURL(for: change)) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.fileURL(for: change)]) }
        }
        if change.kind != .new {
            Button("Open \(project.changeSet?.baseBranch ?? "Base") Version") { project.openBaseImage(for: change) }
        }
        Divider()
        Button("Copy Side-by-Side Image") { Clipboard.copyComparison(project.imageLoader(for: change)) }
        let viewed = project.viewedChanges.contains(change.id)
        Button(viewed ? "Mark as Not Viewed" : "Mark as Viewed") { project.setViewed(!viewed, for: change) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(change.path, forType: .string)
        }
        Divider()
        if project.canDiscard(change) {
            Button("Discard Change…", role: .destructive) { pendingDiscard = change }
        }
        Button("Revert to \(baseName)…", role: .destructive) { pendingRevert = [change] }
            .disabled(project.isRunning)
    }

    /// Search, then what to compare against: level with the detail's header and info row.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneBar(height: DS.Bar.header) {
                SearchField(prompt: "Filter suites and tests", text: $project.changeFilter, focusRequest: project.focusFilterRequest)
                GlassIconButton(title: "Refresh", symbol: "arrow.clockwise", help: "Compare again (also happens when you come back to the app)") {
                    project.refreshChanges()
                }
            }
            PaneBar(height: DS.Bar.filters) {
                Menu {
                    ForEach(project.branches, id: \.self) { branch in
                        Button {
                            project.setBaseBranch(branch)
                        } label: {
                            if branch == project.baseBranch { Label(branch, systemImage: "checkmark") } else { Text(branch) }
                        }
                    }
                    if project.settings.baseBranch != nil {
                        Divider()
                        Button("Use Detected Branch") { project.setBaseBranch(nil) }
                    }
                } label: {
                    Label(project.baseBranch ?? "Base Branch", systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // The one control here that gives way: branch names can be long.
                .frame(minWidth: 60)
                .layoutPriority(-1)
                .quietControl()
                .help("The branch to compare against")
                .accessibilityLabel("Base branch: \(project.baseBranch ?? "none")")

                Menu {
                    Picker("Compare with", selection: $project.diffBase) {
                        ForEach(DiffBase.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(project.diffBase.label)
                }
                .fixedSize()
                .quietControl()
                .accessibilityLabel("Compare with")
                .help("Merge-base shows only this branch’s changes; branch tip also shows changes made on the base branch since.")

                Menu {
                    ForEach(SnapshotChangeKind.allCases, id: \.self) { kind in
                        Toggle("\(kind.label) (\(count(kind)))", isOn: Binding(
                            get: { project.changeKinds.contains(kind) },
                            set: { on in if on { project.changeKinds.insert(kind) } else { project.changeKinds.remove(kind) } }
                        ))
                    }
                    Divider()
                    Toggle("Hide Viewed (\(project.viewedChanges.count))", isOn: $project.hideViewed)
                    Button("Mark All as Viewed") { project.setAllViewed(true) }
                        .disabled(project.displayedChanges.allSatisfy { project.viewedChanges.contains($0.id) })
                    Button("Mark All as Not Viewed") { project.setAllViewed(false) }
                        .disabled(!project.displayedChanges.contains { project.viewedChanges.contains($0.id) })
                    Button("Revert All Shown to \(baseName)…") { pendingRevert = project.displayedChanges }
                        .disabled(project.displayedChanges.isEmpty || project.isRunning)
                    Divider()
                    Button("Show All") {
                        project.changeKinds = Set(SnapshotChangeKind.allCases)
                        project.hideViewed = false
                    }
                } label: {
                    Label(kindsLabel, systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
                .quietControl()
                .help("Which kinds of change to show: committed, uncommitted, new, deleted; and whether to hide viewed ones")
                .accessibilityLabel("Change kinds: \(kindsLabel)")
            }
            .controlSize(.small)
            .padding(.bottom, DS.Space.xs)
        }
    }

    /// How many are shown, what they're compared with, and how far the review has got.
    @ViewBuilder
    private var footer: some View {
        if let set = project.changeSet {
            PaneFooter {
                // "18 changes", or "5 of 18" while filtered.
                let shown = project.filteredChanges.count, total = set.changes.count
                Text((total == 0 ? "" : shown == total ? "\(total) change\(total == 1 ? "" : "s") · " : "\(shown) of \(total) · ")
                     + "vs \(set.baseRef) @ \(set.baseCommit.prefix(7))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Space.s)
                if !set.changes.isEmpty {
                    let viewed = set.changes.filter { project.viewedChanges.contains($0.id) }.count
                    Gauge(value: Double(viewed), in: 0...Double(set.changes.count)) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(DS.Status.passed)
                        .frame(width: 44)
                        .accessibilityHidden(true)
                    Text("\(viewed)/\(set.changes.count) viewed").monospacedDigit().fixedSize()
                }
            }
        }
    }

    /// What this change is compared with, what kind of difference it is, and the way to the library.
    private func infoRow(_ change: SnapshotChange) -> some View {
        DetailInfoRow {
            ChangeOrigin(project: project, change: change)
            if let chip = project.changeDiagnoses[change.id].flatMap(DiagnosisChip.init) { chip }
            Spacer(minLength: DS.Space.s)
            Button("Show in Library") { project.showInLibrary(path: change.path) }
                .quietControl()
                .disabled(change.kind == .deleted || !project.isInLibrary(change.path))
                .help("Open this snapshot in the library, with its variants and history")
        }
        .padding(.bottom, DS.Space.xs)
        .background(DS.Surface.content)
    }

    /// Re-records that only picked up rendering noise would add churn to the merge request.
    private var invisibleNotice: some View {
        let count = project.invisibleUncommitted.count
        return VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "eye.slash").foregroundStyle(DS.Status.changed).accessibilityHidden(true)
                Text("\(count) uncommitted snapshot\(count == 1 ? " has" : "s have") no visible change.")
                    .font(DS.Font.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s)
                Button("Discard…") { confirmDiscardInvisible = true }
                    .controlSize(.small)
                    .quietControl()
                    .help("Restore them to the committed version, so only real changes get committed")
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            Divider()
        }
    }

    private func count(_ kind: SnapshotChangeKind) -> Int {
        project.changeSet?.changes.filter { $0.kind == kind }.count ?? 0
    }

    private var kindsLabel: String {
        let kinds = project.changeKinds.count == SnapshotChangeKind.allCases.count
            ? "All"
            : "\(project.changeKinds.count) of \(SnapshotChangeKind.allCases.count)"
        return project.hideViewed ? kinds + ", Unviewed" : kinds
    }

    @ViewBuilder
    private var list: some View {
        if let error = project.changesError {
            ContentUnavailableView("Can’t Compare", systemImage: "arrow.triangle.branch", description: Text(error))
        } else if project.isLoadingChanges && project.changeSet == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let groups = SnapshotChangeSet.group(project.filteredChanges)
            List(selection: $project.selectedChangeID) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.changes) { change in
                            ChangeRow(change: change, variant: project.showsVariant(change.file) ? change.file.variant : nil,
                                      viewed: project.viewedChanges.contains(change.id),
                                      diagnosis: project.changeDiagnoses[change.id], load: project.imageLoader(for: change))
                                .tag(change.id)
                                .selectableRow(project.selectedChangeID == change.id)
                                .contextMenu { actions(for: change) }
                        }
                    } header: {
                        ListSectionHeader(title: group.suite, count: group.changes.count)
                    }
                }
            }
            .onKeyPress(.space) {
                guard let change = project.selectedChange, change.kind != .deleted else { return .ignored }
                quickLookURL = project.fileURL(for: change)
                return .handled
            }
            .quickLookPreview($quickLookURL)
            // ⌘C copies the selected snapshot as it is now (a deleted one as it was).
            .onCopyCommand {
                guard let change = project.selectedChange else { return [] }
                if change.kind != .deleted, let item = NSItemProvider(contentsOf: project.fileURL(for: change)) { return [item] }
                guard let data = project.imageLoader(for: change)().0 else { return [] }
                return [NSItemProvider(item: data as NSData, typeIdentifier: "public.png")]
            }
            .onKeyPress("v") {
                guard let change = project.selectedChange else { return .ignored }
                project.setViewed(!project.viewedChanges.contains(change.id), for: change)
                return .handled
            }
            .overlay {
                if groups.isEmpty {
                    if project.hideViewed && !(project.changeSet?.changes.isEmpty ?? true) && project.changeFilter.isEmpty {
                        ContentUnavailableView("All Snapshots Viewed", systemImage: "checkmark.circle",
                                               description: Text("Turn off Hide Viewed to see them again."))
                    } else if project.changeSet?.changes.isEmpty == true {
                        ContentUnavailableView("No Changed Snapshots", systemImage: "checkmark.circle",
                                               description: Text("Every PNG matches \(project.baseBranch ?? "the base branch")."))
                    } else {
                        ContentUnavailableView.search(text: project.changeFilter)
                    }
                }
            }
        }
    }
}

/// Where a change comes from: the commit that last touched the snapshot on this branch (who,
/// when, why), or that it isn't committed yet. Until the history is read, and when there is none,
/// it says what is compared instead.
struct ChangeOrigin: View {
    let project: ProjectModel
    var change: SnapshotChange
    @State private var last: SnapshotVersion?
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: last == nil ? "arrow.triangle.branch" : "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            text
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .task(id: change.id) {
            last = nil
            // A deletion may not be committed yet, so its last commit could predate it.
            guard change.kind == .committed else { return }
            last = await project.history(of: change.file).first
        }
    }

    private var text: Text {
        if change.kind == .uncommitted || change.kind == .new {
            return Text("Not committed yet · compared with \(project.changeSet?.baseBranch ?? "the base branch")")
        }
        guard let last else {
            return Text("\(project.changeSet?.baseBranch ?? "Base") at \(project.diffBase.label.lowercased()) → this branch")
        }
        return Text("Changed \(last.date.formatted(.dateTime.day().month(.abbreviated).locale(locale))) by \(last.author) in ")
            + Text(last.shortCommit).font(DS.Font.code)
            + Text(" “\(last.subject)”")
    }
}

extension SnapshotChange {
    /// The change read as a library file, for its test name and variant ("payButton", "dark").
    var file: SnapshotFile { SnapshotFile(path: path, byteSize: 0) }
}

struct ChangeRow: View {
    // Read as one element: "payButton, Committed".
    var change: SnapshotChange
    /// The variant to show ("dark"), or nil when it says nothing (see `ProjectModel.showsVariant`).
    var variant: String?
    var viewed = false
    var diagnosis: DiffDiagnosis?
    var load: @Sendable () -> (Data?, Data?)

    var body: some View {
        let load = load
        HStack(spacing: DS.Space.m) {
            Thumbnail(id: "change:\(change.path)#\(change.kind)") {
                let (base, current) = load()
                return current ?? base
            }
            .opacity(viewed ? 0.5 : 1)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(change.file.testName).fontWeight(.medium).lineLimit(1)
                    .foregroundStyle(viewed ? .secondary : .primary)
                HStack(spacing: DS.Space.xs) {
                    Circle().fill(DS.Status.color(for: change.kind)).frame(width: DS.Status.dot, height: DS.Status.dot)
                    // Named like the library: the variant in code type, not the file name.
                    (Text(change.kind.label) + Text(variant == nil ? "" : " · ")
                        + Text(variant ?? "").font(DS.Font.code))
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let chip = diagnosis.flatMap(DiagnosisChip.init) { chip }
                }
            }
            Spacer(minLength: DS.Space.s)
            if viewed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .help("Viewed")
            }
        }
        .padding(.vertical, DS.Space.xxs)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(change.file.testName) \(variant ?? ""), \(change.kind.label), in \(change.suite)\(viewed ? ", viewed" : "")")
    }
}

/// The header bar of a detail pane: what it is, where it lives, where it is in the list, and its
/// actions. Its height is fixed (`DS.Bar.header`), level with the list's search bar.
struct DetailHeader<Accessory: View>: View {
    var title: String
    /// Where it lives, as a breadcrumb ("Module › Suite").
    var subtitle: String?
    /// The full file path, shown on hover (and copied from the actions menu).
    var path: String?
    /// One-based position in the list and the list's length, for the previous/next stepper.
    var position: (index: Int, count: Int)?
    var step: (Int) -> Void = { _ in }
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(DS.Font.heading).lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path ?? subtitle)
                }
            }
            Spacer(minLength: DS.Space.s)
            accessory
            if let position, position.count > 0 {
                PositionStepper(position: position.index, count: position.count, step: step)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(maxWidth: .infinity, minHeight: DS.Bar.header, maxHeight: DS.Bar.header)
        .background(DS.Surface.content)
    }
}

/// The row under a detail header (history, variants, what it's compared with). Fixed height, level
/// with the list's filter bar, so the image below starts at the same place in every snapshot.
struct DetailInfoRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: DS.Space.m) { content }
            .controlSize(.small)
            .font(DS.Font.secondary)
            .padding(.horizontal, DS.Space.l)
            .frame(maxWidth: .infinity, minHeight: DS.Bar.filters, maxHeight: DS.Bar.filters, alignment: .leading)
            .background(DS.Surface.content)
    }
}

struct SearchField: View {
    var prompt: String
    @Binding var text: String
    /// Bumped by ⌘F (Filter…) to put the cursor here.
    var focusRequest = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onChange(of: focusRequest) { _, _ in focused = true }
                .onKeyPress(.escape) {
                    // Escape clears the filter first, then leaves the field.
                    if text.isEmpty { focused = false } else { text = "" }
                    return .handled
                }
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear")
            }
        }
        .fieldChrome()
    }
}

