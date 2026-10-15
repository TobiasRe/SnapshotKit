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
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)

            Group {
                if let change = project.selectedChange {
                    VStack(spacing: 0) {
                        HStack {
                            KindBadge(kind: change.kind)
                            Text(change.path).font(.callout).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        Divider()
                        CompareView(load: project.imageLoader(for: change),
                                    beforeLabel: "\(project.changeSet?.baseBranch ?? "base") (\(project.diffBase.label.lowercased()))",
                                    afterLabel: change.kind == .uncommitted || change.kind == .new ? "Working tree" : "This branch",
                                    identity: change.id + "#" + (project.changeSet?.baseCommit ?? "") + "#\(change.kind)")
                    }
                } else {
                    Text(project.changeSet == nil ? "" : "Select a snapshot to compare")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420)
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter by suite, test or path", text: $project.changeFilter)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 4) {
                ForEach(SnapshotChangeKind.allCases, id: \.self) { kind in
                    let count = project.changeSet?.changes.filter { $0.kind == kind }.count ?? 0
                    Toggle(isOn: Binding(
                        get: { project.changeKinds.contains(kind) },
                        set: { on in if on { project.changeKinds.insert(kind) } else { project.changeKinds.remove(kind) } }
                    )) {
                        Text("\(kind.label) \(count)").font(.caption)
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
            }
            HStack {
                Picker("Compare with", selection: $project.diffBase) {
                    ForEach(DiffBase.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                Spacer()
                Button { project.refreshChanges() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            if let set = project.changeSet {
                Text("vs \(set.baseRef) @ \(set.baseCommit.prefix(8))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var list: some View {
        if let error = project.changesError {
            Text(error).foregroundStyle(.secondary).padding().frame(maxHeight: .infinity, alignment: .top)
        } else if project.isLoadingChanges && project.changeSet == nil {
            ProgressView().frame(maxHeight: .infinity)
        } else {
            let groups = SnapshotChangeSet.group(project.filteredChanges)
            List(selection: $project.selectedChangeID) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.changes) { change in
                            HStack(spacing: 6) {
                                KindBadge(kind: change.kind)
                                Text(change.fileName).lineLimit(1)
                            }
                            .tag(change.id)
                        }
                    } header: {
                        Text("\(group.suite) (\(group.changes.count))")
                    }
                }
            }
            .overlay {
                if groups.isEmpty {
                    Text(project.changeSet?.changes.isEmpty == true ? "No snapshots differ from \(project.baseBranch ?? "the base branch")." : "No snapshots match the filter.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
    }
}

struct KindBadge: View {
    var kind: SnapshotChangeKind

    var body: some View {
        Text(short)
            .font(.caption2.weight(.bold))
            .frame(width: 18, height: 16)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.2)))
            .foregroundStyle(color)
            .help(kind.label)
    }

    private var short: String {
        switch kind {
        case .committed: "C"
        case .uncommitted: "M"
        case .new: "N"
        case .deleted: "D"
        }
    }

    private var color: Color {
        switch kind {
        case .committed: .blue
        case .uncommitted: .orange
        case .new: .green
        case .deleted: .red
        }
    }
}
