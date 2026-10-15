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
                } else if !project.historyFlaky.isEmpty {
                    flakyHistory
                } else {
                    ContentUnavailableView("No Failure Selected", systemImage: "rectangle.on.rectangle.slash",
                                           description: Text(project.failures.isEmpty
                                                             ? "Failing snapshot tests from the last run appear here."
                                                             : "Select a failing test to compare it with its reference."))
                }
            }
            .frame(minWidth: 440)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.failureSource?.label ?? "No results yet")
                        .font(.headline)
                    if let source = project.failureSource {
                        (Text("\(source.host) · ") + Text(source.date, format: .dateTime.day().month(.abbreviated).year().hour().minute()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { app.importResultBundleFromPanel() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import an .xcresult, for example from a CI job (⇧⌘O)")
            }
            HStack(spacing: 8) {
                Button("Re-record All") { project.reRecordFailed() }
                    .disabled(project.isRunning || project.failingSuites.isEmpty)
                Button("Check Flakiness") { project.checkFlakiness() }
                    .disabled(project.isRunning || project.failingSuites.isEmpty)
            }
        }
        .controlSize(.small)
        .padding(12)
    }

    private var list: some View {
        let bySuite = Dictionary(grouping: project.failures, by: \.suite.identifier)
        return List(selection: $project.selectedFailureID) {
            ForEach(bySuite.keys.sorted(), id: \.self) { suite in
                Section {
                    ForEach(bySuite[suite] ?? []) { item in
                        FailureRow(item: item, repositoryURL: project.project.url)
                            .tag(item.id)
                    }
                } header: {
                    HStack {
                        Text(suite)
                        Spacer()
                        Text("\(bySuite[suite]?.count ?? 0)").monospacedDigit()
                    }
                }
            }
        }
        .overlay {
            if project.failures.isEmpty {
                ContentUnavailableView("Nothing Failing", systemImage: "checkmark.circle",
                                       description: Text("Run the tests, or import a result bundle from CI."))
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
            DetailHeader(title: item.test.name, subtitle: item.referencePaths.first ?? item.suite.identifier) {
                HStack(spacing: 8) {
                    if let verdict = item.verdict { VerdictTag(verdict: verdict) }
                    if reps.count > 1 {
                        Picker("Repetition", selection: $repetition) {
                            ForEach(reps, id: \.self) { Text("Run \($0) of \(reps.count)").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Button("Re-record Suite") { project.reRecordFailed(suites: [item.suite]) }
                        .disabled(project.isRunning)
                }
                .controlSize(.small)
            }
            if let message = item.test.failureMessages.first {
                VStack(alignment: .leading, spacing: 4) {
                    Label(firstLine(message), systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    hint(item)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            Divider()
            if referenceURL != nil || failureURL != nil {
                CompareView(load: { (referenceURL.flatMap { try? Data(contentsOf: $0) }, failureURL.flatMap { try? Data(contentsOf: $0) }) },
                            beforeLabel: "Reference",
                            afterLabel: "Actual · \(image?.device ?? project.failureSource?.host ?? "run")",
                            identity: item.id + "#\(rep)")
            } else {
                ContentUnavailableView("No Images Attached", systemImage: "photo.badge.exclamationmark",
                                       description: Text("This failure has no snapshot images; it may not be a snapshot mismatch."))
            }
        }
    }

    @ViewBuilder
    private func hint(_ item: FailureItem) -> some View {
        switch item.verdict {
        case .flaky:
            Label("Passes sometimes, so re-recording will not fix it. Look for animations, async loading, dates or random data.", systemImage: "lightbulb")
                .foregroundStyle(.orange)
        case .alwaysFails:
            Label("Fails every time: re-record if the change is intended, otherwise it is a regression.", systemImage: "lightbulb")
                .foregroundStyle(.secondary)
        case .passes:
            Label("Did not reproduce in the flakiness check.", systemImage: "lightbulb")
                .foregroundStyle(.secondary)
        case nil:
            if item.historyFlaky != nil {
                Label("Both passed and failed on the same commit in earlier runs.", systemImage: "lightbulb")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var flakyHistory: some View {
        Form {
            Section {
                ForEach(project.historyFlaky) { signal in
                    LabeledContent {
                        Text("\(signal.passes) passed · \(signal.failures) failed")
                    } label: {
                        Text(signal.test).font(.callout.monospaced())
                        Text("Failing on \(signal.failingHosts.joined(separator: ", "))")
                    }
                }
            } header: {
                Text("Flaky in Run History")
            } footer: {
                Text("These tests both passed and failed on the same commit with a clean working tree.")
            }
        }
        .formStyle(.grouped)
    }

    private func firstLine(_ message: String) -> String {
        message.split(separator: "\n").first.map(String.init) ?? message
    }
}

struct FailureRow: View {
    var item: FailureItem
    var repositoryURL: URL

    var body: some View {
        let failure = item.images.first?.failure
        let reference = item.images.first?.reference ?? item.referencePaths.first.map { repositoryURL.appendingPathComponent($0) }
        HStack(spacing: 10) {
            Thumbnail(id: "failure:\(item.id)#\(failure?.path ?? reference?.path ?? "")") {
                (failure ?? reference).flatMap { try? Data(contentsOf: $0) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.test.name).lineLimit(1)
                HStack(spacing: 4) {
                    if let verdict = item.verdict { VerdictTag(verdict: verdict) }
                    if item.test.repetitions.count > 1 {
                        Chip(text: "\(item.test.failedRepetitions)/\(item.test.repetitions.count) runs failed", color: .secondary)
                    }
                    if let flaky = item.historyFlaky {
                        Chip(text: "Flaky in history · \(flaky.passes)/\(flaky.passes + flaky.failures) passed", color: .orange)
                    }
                    if item.verdict == nil && item.test.repetitions.count <= 1 && item.historyFlaky == nil {
                        Text(item.images.isEmpty ? "No images" : "Snapshot mismatch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct VerdictTag: View {
    var verdict: FlakeVerdict

    var body: some View {
        switch verdict {
        case .alwaysFails: Chip(text: verdict.label, color: DS.Status.failed)
        case .flaky: Chip(text: verdict.label, color: DS.Status.flaky)
        case .passes: Chip(text: verdict.label, color: DS.Status.passed)
        }
    }
}
