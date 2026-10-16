import AppKit
import SnapshotKitCore
import SwiftUI

struct ChangesTab: View {
    @ObservedObject var project: ProjectModel
    @State private var pendingDiscard: SnapshotChange?
    @State private var confirmDiscardInvisible = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                if !project.invisibleUncommitted.isEmpty { invisibleNotice }
                list
                    .frame(maxHeight: .infinity)
            }
            .frame(minWidth: 280, idealWidth: 330, maxWidth: 460, maxHeight: .infinity, alignment: .top)

            Group {
                if let change = project.selectedChange {
                    VStack(spacing: 0) {
                        DetailHeader(title: change.testName, subtitle: change.path) {
                            HStack(spacing: DS.Space.s) {
                                KindBadge(kind: change.kind, style: .label)
                                Toggle("Viewed", isOn: Binding(
                                    get: { project.viewedChanges.contains(change.id) },
                                    set: { project.setViewed($0, for: change) }
                                ))
                                .toggleStyle(.checkbox)
                                .help("Mark as reviewed and go to the next snapshot (V in the list)")
                                Menu {
                                    actions(for: change)
                                } label: {
                                    Label("Snapshot Actions", systemImage: "ellipsis")
                                }
                                .labelStyle(.iconOnly)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("Open, reveal or discard this snapshot")
                                .accessibilityLabel("Snapshot Actions")
                            }
                        }
                        Divider()
                        CompareView(load: project.imageLoader(for: change),
                                    beforeLabel: "\(project.changeSet?.baseBranch ?? "Base") · \(project.diffBase.label.lowercased())",
                                    afterLabel: change.kind == .uncommitted || change.kind == .new ? "Working tree" : "This branch",
                                    identity: change.id + "#" + (project.changeSet?.baseCommit ?? "") + "#\(change.kind)")
                    }
                } else if project.changesError != nil {
                    ContentUnavailableView("Choose a Base Branch", systemImage: "arrow.triangle.branch",
                                           description: Text("Pick the branch your merge requests target from the base branch menu above the list."))
                } else if project.changeSet != nil {
                    ContentUnavailableView("No Snapshot Selected", systemImage: "photo.on.rectangle",
                                           description: Text("Select a changed snapshot to compare it with \(project.baseBranch ?? "the base branch")."))
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
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
        // Pick up re-records or edits made outside the app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            project.refreshChanges()
        }
    }

    @ViewBuilder
    private func actions(for change: SnapshotChange) -> some View {
        if change.kind != .deleted {
            Button("Open in Default App") { NSWorkspace.shared.open(project.fileURL(for: change)) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.fileURL(for: change)]) }
        }
        if change.kind != .new {
            Button("Open \(project.changeSet?.baseBranch ?? "Base") Version") {
                if let url = project.exportBaseImage(for: change) { NSWorkspace.shared.open(url) }
            }
        }
        Divider()
        Button("Copy Side-by-Side Image") { Clipboard.copyComparison(project.imageLoader(for: change)) }
        let viewed = project.viewedChanges.contains(change.id)
        Button(viewed ? "Mark as Not Viewed" : "Mark as Viewed") { project.setViewed(!viewed, for: change) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(change.path, forType: .string)
        }
        if project.canDiscard(change) {
            Divider()
            Button("Discard Change…", role: .destructive) { pendingDiscard = change }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SearchField(prompt: "Filter suites and tests", text: $project.changeFilter)
            HStack(spacing: DS.Space.s) {
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
                }
                .fixedSize()
                .help("The branch to compare against")
                .accessibilityLabel("Base branch: \(project.baseBranch ?? "none")")

                Picker("Compare with", selection: $project.diffBase) {
                    ForEach(DiffBase.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Compare with")
                .help("Merge-base shows only this branch's changes; branch tip also shows changes made on the base branch since.")

                Menu {
                    ForEach(SnapshotChangeKind.allCases, id: \.self) { kind in
                        Toggle("\(kind.label) (\(count(kind)))", isOn: Binding(
                            get: { project.changeKinds.contains(kind) },
                            set: { on in if on { project.changeKinds.insert(kind) } else { project.changeKinds.remove(kind) } }
                        ))
                    }
                    Divider()
                    Toggle("Hide Viewed (\(project.viewedChanges.count))", isOn: $project.hideViewed)
                    Divider()
                    Button("Show All") {
                        project.changeKinds = Set(SnapshotChangeKind.allCases)
                        project.hideViewed = false
                    }
                } label: {
                    Label(kindsLabel, systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
                .accessibilityLabel("Show: \(kindsLabel)")

                Spacer()
                Button { project.refreshChanges() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
            }
            .controlSize(.small)
            if let set = project.changeSet {
                HStack(spacing: DS.Space.s) {
                    Text("\(project.filteredChanges.count) of \(set.changes.count) snapshots · vs \(set.baseRef) @ \(set.baseCommit.prefix(7))")
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
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(DS.Space.m)
    }

    /// Re-records that only picked up rendering noise would add churn to the merge request.
    private var invisibleNotice: some View {
        let count = project.invisibleUncommitted.count
        return VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "eye.slash").foregroundStyle(DS.Status.flaky).accessibilityHidden(true)
                Text("\(count) uncommitted snapshot\(count == 1 ? " has" : "s have") no visible change.")
                    .font(DS.Font.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s)
                Button("Discard…") { confirmDiscardInvisible = true }
                    .controlSize(.small)
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
            ? "All Changes"
            : "\(project.changeKinds.count) of \(SnapshotChangeKind.allCases.count) Kinds"
        return project.hideViewed ? kinds + ", Unviewed" : kinds
    }

    @ViewBuilder
    private var list: some View {
        if let error = project.changesError {
            ContentUnavailableView("Can't Compare", systemImage: "arrow.triangle.branch", description: Text(error))
        } else if project.isLoadingChanges && project.changeSet == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let groups = SnapshotChangeSet.group(project.filteredChanges)
            List(selection: $project.selectedChangeID) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.changes) { change in
                            ChangeRow(change: change, viewed: project.viewedChanges.contains(change.id),
                                      diagnosis: project.changeDiagnoses[change.id], load: project.imageLoader(for: change))
                                .tag(change.id)
                                .contextMenu { actions(for: change) }
                        }
                    } header: {
                        HStack {
                            Text(group.suite)
                            Spacer()
                            Text("\(group.changes.count)").monospacedDigit()
                        }
                    }
                }
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

struct ChangeRow: View {
    // Read as one element: "payButton, Committed".
    var change: SnapshotChange
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
                Text(change.testName).lineLimit(1)
                    .foregroundStyle(viewed ? .secondary : .primary)
                HStack(spacing: DS.Space.xs) {
                    KindBadge(kind: change.kind, style: .dot)
                    Text("\(change.kind.label) · \(change.fileName)")
                        .font(.caption)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(change.testName), \(change.kind.label), in \(change.suite)\(viewed ? ", viewed" : "")")
    }
}

/// Title row above a detail pane.
struct DetailHeader<Accessory: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(.headline).lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            accessory
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }
}

struct SearchField: View {
    var prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear")
            }
        }
        // A fixed height: a focused field (the field editor) is otherwise a couple of points
        // taller, and focus arrives at an unpredictable moment, which moved everything below.
        .frame(height: 16)
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct KindBadge: View {
    enum Style { case dot, label }
    var kind: SnapshotChangeKind
    var style: Style = .dot

    var body: some View {
        switch style {
        case .dot:
            Circle().fill(color).frame(width: 7, height: 7)
                .help(kind.label)
        case .label:
            Text(kind.label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
                .background(Capsule().fill(color.opacity(0.15)))
                .foregroundStyle(DS.Status.text(color))
        }
    }

    private var color: Color { DS.Status.color(for: kind) }
}
