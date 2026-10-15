import SnapshotKitCore
import SwiftUI

struct ChangesTab: View {
    @ObservedObject var project: ProjectModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                list
            }
            .frame(minWidth: 280, idealWidth: 330, maxWidth: 460)

            Group {
                if let change = project.selectedChange {
                    VStack(spacing: 0) {
                        DetailHeader(title: change.testName, subtitle: change.path) {
                            KindBadge(kind: change.kind, style: .label)
                        }
                        Divider()
                        CompareView(load: project.imageLoader(for: change),
                                    beforeLabel: "\(project.changeSet?.baseBranch ?? "Base") · \(project.diffBase.label.lowercased())",
                                    afterLabel: change.kind == .uncommitted || change.kind == .new ? "Working tree" : "This branch",
                                    identity: change.id + "#" + (project.changeSet?.baseCommit ?? "") + "#\(change.kind)")
                    }
                } else if project.changeSet != nil {
                    ContentUnavailableView("No Snapshot Selected", systemImage: "photo.on.rectangle",
                                           description: Text("Select a changed snapshot to compare it with \(project.baseBranch ?? "the base branch")."))
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 440)
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchField(prompt: "Filter suites and tests", text: $project.changeFilter)
            HStack(spacing: 8) {
                Picker("Compare with", selection: $project.diffBase) {
                    ForEach(DiffBase.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Merge-base shows only this branch's changes; branch tip also shows changes made on the base branch since.")

                Menu {
                    ForEach(SnapshotChangeKind.allCases, id: \.self) { kind in
                        Toggle("\(kind.label) (\(count(kind)))", isOn: Binding(
                            get: { project.changeKinds.contains(kind) },
                            set: { on in if on { project.changeKinds.insert(kind) } else { project.changeKinds.remove(kind) } }
                        ))
                    }
                    Divider()
                    Button("Show All") { project.changeKinds = Set(SnapshotChangeKind.allCases) }
                } label: {
                    Label(kindsLabel, systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()

                Spacer()
                Button { project.refreshChanges() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            .controlSize(.small)
            if let set = project.changeSet {
                Text("\(project.filteredChanges.count) of \(set.changes.count) snapshots · vs \(set.baseRef) @ \(set.baseCommit.prefix(7))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func count(_ kind: SnapshotChangeKind) -> Int {
        project.changeSet?.changes.filter { $0.kind == kind }.count ?? 0
    }

    private var kindsLabel: String {
        project.changeKinds.count == SnapshotChangeKind.allCases.count
            ? "All Changes"
            : "\(project.changeKinds.count) of \(SnapshotChangeKind.allCases.count) Kinds"
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
                            ChangeRow(change: change, load: project.imageLoader(for: change))
                                .tag(change.id)
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
            .overlay {
                if groups.isEmpty {
                    if project.changeSet?.changes.isEmpty == true {
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
    var change: SnapshotChange
    var load: @Sendable () -> (Data?, Data?)

    var body: some View {
        let load = load
        HStack(spacing: 10) {
            Thumbnail(id: "change:\(change.path)#\(change.kind)") {
                let (base, current) = load()
                return current ?? base
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(change.testName).lineLimit(1)
                HStack(spacing: 5) {
                    KindBadge(kind: change.kind, style: .dot)
                    Text("\(change.kind.label) · \(change.fileName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Title row above a detail pane.
struct DetailHeader<Accessory: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct SearchField: View {
    var prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
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
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.15)))
                .foregroundStyle(color)
        }
    }

    private var color: Color { DS.Status.color(for: kind) }
}
