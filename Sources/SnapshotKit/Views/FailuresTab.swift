import SnapshotKitCore
import SwiftUI

struct FailuresTab: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var project: ProjectModel
    @State private var repetition = 1

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                list
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 480)

            Group {
                if let item = project.selectedFailure {
                    detail(item)
                } else {
                    VStack(spacing: 8) {
                        Text(project.failures.isEmpty ? "No failing snapshot tests" : "Select a failing test")
                            .foregroundStyle(.secondary)
                        if !project.historyFlaky.isEmpty {
                            flakyHistory
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = project.failureSource {
                Text("\(source.label) · \(source.host) · \(source.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Re-record All") { project.reRecordFailed() }
                    .disabled(project.isRunning || project.failingSuites.isEmpty)
                Button("Check Flakiness") { project.checkFlakiness() }
                    .disabled(project.isRunning || project.failingSuites.isEmpty)
                Spacer()
                Button { app.importResultBundleFromPanel() } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless)
                    .help("Import an .xcresult (for example from a CI job) — ⇧⌘O")
            }
            .controlSize(.small)
        }
        .padding(10)
    }

    private var list: some View {
        let bySuite = Dictionary(grouping: project.failures, by: \.suite.identifier)
        return List(selection: $project.selectedFailureID) {
            ForEach(bySuite.keys.sorted(), id: \.self) { suite in
                Section(suite) {
                    ForEach(bySuite[suite] ?? []) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.test.name).lineLimit(1)
                            HStack(spacing: 4) {
                                if item.test.repetitions.count > 1 {
                                    Tag(text: "\(item.test.failedRepetitions)/\(item.test.repetitions.count) failed", color: .secondary)
                                }
                                if let verdict = item.verdict { VerdictTag(verdict: verdict) }
                                if let flaky = item.historyFlaky {
                                    Tag(text: "flaky in history (\(flaky.passes)✔ \(flaky.failures)✘)", color: .orange)
                                }
                                if item.images.isEmpty { Tag(text: "no images", color: .secondary) }
                            }
                        }
                        .tag(item.id)
                    }
                }
            }
        }
        .overlay {
            if project.failures.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing failing").foregroundStyle(.secondary)
                    Text("Run the tests, or import a result bundle from CI.").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func detail(_ item: FailureItem) -> some View {
        let reps = Array(Set(item.images.map(\.repetition))).sorted()
        let rep = reps.contains(repetition) ? repetition : (reps.first ?? 1)
        let image = item.images.first { $0.repetition == rep }
        let referenceURL = image?.reference ?? item.referencePaths.first.map { project.project.url.appendingPathComponent($0) }
        let failureURL = image?.failure

        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.test.name).font(.headline)
                    if let verdict = item.verdict { VerdictTag(verdict: verdict) }
                    Spacer()
                    if reps.count > 1 {
                        Picker("Repetition", selection: $repetition) {
                            ForEach(reps, id: \.self) { Text("Run \($0)").tag($0) }
                        }
                        .fixedSize()
                    }
                    Button("Re-record Suite") { project.reRecordFailed(suites: [item.suite]) }
                        .disabled(project.isRunning)
                }
                if let path = item.referencePaths.first {
                    Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let message = item.test.failureMessages.first {
                    Text(firstLine(message))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                hint(item)
            }
            .padding(10)
            Divider()
            if referenceURL != nil || failureURL != nil {
                CompareView(load: { (referenceURL.flatMap { try? Data(contentsOf: $0) }, failureURL.flatMap { try? Data(contentsOf: $0) }) },
                            beforeLabel: "Reference", afterLabel: "Actual (\(image?.device ?? project.failureSource?.host ?? "run"))",
                            identity: item.id + "#\(rep)")
            } else {
                Text("This failure has no snapshot images attached (it may not be a snapshot mismatch).")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func hint(_ item: FailureItem) -> some View {
        switch item.verdict {
        case .flaky:
            Label("Passes sometimes: re-recording will not fix this. Look for animations, async loading, dates or random data in the view.", systemImage: "lightbulb")
                .font(.caption).foregroundStyle(.orange)
        case .alwaysFails:
            Label("Fails every time: an intended change needs a re-record; otherwise it is a regression.", systemImage: "lightbulb")
                .font(.caption).foregroundStyle(.secondary)
        case .passes:
            Label("Did not reproduce in the flakiness check.", systemImage: "lightbulb")
                .font(.caption).foregroundStyle(.secondary)
        case nil:
            if item.historyFlaky != nil {
                Label("This test both passed and failed on the same commit in earlier runs.", systemImage: "lightbulb")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var flakyHistory: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Flaky in run history").font(.headline)
            ForEach(project.historyFlaky) { signal in
                Text("\(signal.test) — \(signal.passes)✔ \(signal.failures)✘ (failing on \(signal.failingHosts.joined(separator: ", ")))")
                    .font(.caption)
            }
        }
        .padding()
    }

    private func firstLine(_ message: String) -> String {
        message.split(separator: "\n").first.map(String.init) ?? message
    }
}

struct Tag: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

struct VerdictTag: View {
    var verdict: FlakeVerdict

    var body: some View {
        switch verdict {
        case .alwaysFails: Tag(text: verdict.label, color: .red)
        case .flaky: Tag(text: verdict.label, color: .orange)
        case .passes: Tag(text: verdict.label, color: .green)
        }
    }
}
