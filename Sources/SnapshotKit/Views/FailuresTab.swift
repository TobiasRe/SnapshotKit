import AppKit
import SnapshotKitCore
import SwiftUI

struct FailuresTab: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    @State private var repetition = 1

    var body: some View {
        ListDetailSplit {
            VStack(spacing: 0) {
                header
                Divider()
                list
                footer
            }
            .background(DS.Surface.content)
            .frame(maxHeight: .infinity, alignment: .top)
        } detail: {
            Group {
                if project.selectedFailures.count > 1 {
                    BatchFailureDetail(project: project)
                } else if let item = project.selectedFailure {
                    detail(item)
                } else if !project.historyFlaky.isEmpty {
                    flakyHistory
                } else if !project.failures.isEmpty {
                    // Only when there is something to select; an empty list says why on its own.
                    ContentUnavailableView("No Failure Selected", systemImage: "rectangle.on.rectangle.slash",
                                           description: Text("Select a failing test to compare it with its reference."))
                } else {
                    DS.Surface.content
                }
            }
            .frame(minWidth: DS.Pane.minDetailWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Where the results come from, then what to do with all failures: level with the detail's
    /// header and info row.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneBar(height: DS.Bar.header) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(project.failureSource?.label ?? "No results yet")
                        .font(DS.Font.heading)
                        .lineLimit(1)
                    if let source = project.failureSource {
                        (Text("\(source.host) · ") + Text(source.date, format: .dateTime.day().month(.abbreviated).year().hour().minute()))
                            .font(DS.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DS.Space.s)
                GlassSplitButton(title: "Import Result Bundle", symbol: "square.and.arrow.down",
                                 help: "Import an .xcresult, for example from a CI job (⇧⌘O)") {
                    app.importResultBundleFromPanel()
                } menu: {
                    Button("Import Result Bundle…") { app.importResultBundleFromPanel() }
                    if let bundle = project.failureSource?.resultBundle {
                        Button("Open Result Bundle in Xcode") { NSWorkspace.shared.open(bundle) }
                        Button("Reveal Result Bundle in Finder") { NSWorkspace.shared.activateFileViewerSelecting([bundle]) }
                    }
                }
            }
            PaneBar(height: DS.Bar.filters) {
                Button("Re-record All") { project.reRecordFailed() }
                    .quietControl()
                    .disabled(project.isRunning || project.failingSuites.isEmpty)
                    .help("Re-record the failing suites of the last run, then verify (⌥⇧⌘R)")
                Button("Check Flakiness") { project.checkFlakiness() }
                    .quietControl()
                    .disabled(project.isRunning || project.failingSuites.isEmpty)
                    .help("Run the failing tests several times and say which are flaky (⌥⌘R)")
            }
            .padding(.bottom, DS.Space.xs)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var footer: some View {
        if !project.failures.isEmpty {
            let suites = Set(project.failures.map(\.suite.identifier)).count
            let flaky = project.failures.filter { $0.verdict == .flaky || $0.historyFlaky != nil }.count
            PaneFooter {
                Text("\(project.failures.count) failing test\(project.failures.count == 1 ? "" : "s") in \(suites) suite\(suites == 1 ? "" : "s")"
                     + (flaky > 0 ? " · \(flaky) flaky" : ""))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private var list: some View {
        let bySuite = Dictionary(grouping: project.failures, by: \.suite.identifier)
        // ⌘- and ⇧-click select several failures, to re-record or check them together.
        return List(selection: Binding(get: { project.effectiveFailureSelection },
                                       set: { project.selectFailures($0) })) {
            ForEach(bySuite.keys.sorted(), id: \.self) { suite in
                Section {
                    ForEach(bySuite[suite] ?? []) { item in
                        FailureRow(item: item, repositoryURL: project.project.url, diagnosis: project.diagnoses[item.id])
                            .tag(item.id)
                            .selectableRow(project.effectiveFailureSelection.contains(item.id))
                            .contextMenu { actions(for: item) }
                    }
                } header: {
                    ListSectionHeader(title: Breadcrumb.of(identifier: suite), count: bySuite[suite]?.count ?? 0)
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
        // Attempts are numbered among all runs of the test, not only the failing ones with images.
        let runs = max(item.test.repetitions.count, reps.last ?? 1)
        let image = item.images.first { $0.repetition == rep }
        let referenceURL = image?.reference ?? item.referencePaths.first.map { project.project.url.appendingPathComponent($0) }
        let failureURL = image?.failure

        let shown = project.displayedFailures.map(\.id)
        return VStack(spacing: 0) {
            DetailHeader(title: item.test.name,
                         subtitle: Breadcrumb.of(identifier: item.suite.identifier),
                         path: item.referencePaths.first,
                         position: shown.firstIndex(of: item.id).map { ($0 + 1, shown.count) },
                         step: { project.selectAdjacent($0) }) {
                HStack(spacing: DS.Space.s) {
                    GlassSplitButton(title: "Re-record", symbol: "camera",
                                     help: "Record this test's snapshots again, then check that it passes (⇧⌘R)") {
                        project.reRecord(failures: [item])
                    } menu: {
                        Button("Re-record Test") { project.reRecord(failures: [item]) }
                        Button("Re-record Suite \(item.suite.name)") { project.reRecordFailed(suites: [item.suite]) }
                    }
                    .disabled(project.isRunning || project.environment == nil)
                    GlassIconMenu(title: "Test Actions", symbol: "ellipsis", help: "More actions for this test") {
                        actions(for: item)
                    }
                }
                .controlSize(.small)
            }
            // Verdict, recent runs and repetition: one row, level with the list's buttons.
            DetailInfoRow {
                if let verdict = item.verdict { VerdictTag(verdict: verdict) }
                if item.timeline.count > 1 {
                    HistoryStrip(points: item.timeline, size: .regular)
                    Text(HistoryStrip.summary(item.timeline))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let diagnosis = project.diagnoses[item.id], diagnosis.kind != .identical {
                    // No run history to show yet: say what kind of difference this is instead.
                    Text(diagnosis.summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(diagnosis.summary)
                } else if item.verdict == nil {
                    Text("First failure on record").foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: DS.Space.s)
                if reps.count > 1 {
                    Menu {
                        Picker("Repetition", selection: $repetition) {
                            ForEach(reps, id: \.self) { Text("Run \($0) of \(runs)").tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Text("Run \(rep) of \(runs)")
                    }
                    .fixedSize()
                    .quietControl()
                    .accessibilityLabel("Repetition")
                    .help("Which attempt of the flakiness check to show")
                }
            }
            .font(DS.Font.caption)
            .padding(.bottom, DS.Space.xs)
            .background(DS.Surface.content)
            Divider()
            if let message = item.test.failureMessages.first {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Label(firstLine(message), systemImage: "xmark.circle.fill")
                        .foregroundStyle(DS.Status.text(DS.Status.failed))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    hint(item)
                }
                .font(DS.Font.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)
                .background(DS.Surface.content)
                Divider()
            }
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
    private func actions(for item: FailureItem) -> some View {
        Button("Check Flakiness of This Test") { project.checkFlakiness(tests: [item.id]) }
            .disabled(project.isRunning || project.environment == nil)
        Button("Re-record \(item.test.name)") { project.reRecord(failures: [item]) }
            .disabled(project.isRunning || project.environment == nil)
        Button("Re-record Suite \(item.suite.name)") { project.reRecordFailed(suites: [item.suite]) }
            .disabled(project.isRunning || project.environment == nil)
        Divider()
        if let reference = item.referencePaths.first {
            Button("Open Test in Xcode") { project.openTestInXcode(SnapshotFile(path: reference, byteSize: 0)) }
            Button("Show Reference in Library") { project.showInLibrary(path: reference) }
                .disabled(!project.isInLibrary(reference))
            Button("Reveal Reference in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.project.url.appendingPathComponent(reference)])
            }
        }
        if let failure = item.images.first?.failure {
            Button("Open Actual Image") { NSWorkspace.shared.open(failure) }
        }
        Divider()
        if let image = item.images.first {
            Button("Copy Side-by-Side Image") {
                let reference = image.reference, failure = image.failure
                Clipboard.copyComparison { (reference.flatMap { try? Data(contentsOf: $0) }, failure.flatMap { try? Data(contentsOf: $0) }) }
            }
        }
        Button("Copy Test Identifier") { copy(item.id) }
        if let message = item.test.failureMessages.first {
            Button("Copy Failure Message") { copy(message) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder
    private func hint(_ item: FailureItem) -> some View {
        if item.isNewReference {
            Label("This test had no reference yet, so one was just recorded. Run the tests again to check against it.", systemImage: "sparkles")
                .foregroundStyle(.secondary)
        } else {
            verdictHint(item)
        }
    }

    @ViewBuilder
    private func verdictHint(_ item: FailureItem) -> some View {
        switch item.verdict {
        case .flaky:
            Label("Passes sometimes, so re-recording will not fix it. Look for animations, async loading, dates or random data.", systemImage: "lightbulb")
                .foregroundStyle(DS.Status.text(DS.Status.flaky))
        case .alwaysFails where project.diagnoses[item.id]?.kind == .imperceptible:
            Label("Fails every time, but nobody can see the difference: the reference was likely recorded on another machine or OS version. Re-record where CI runs, or relax perceptualPrecision.", systemImage: "lightbulb")
                .foregroundStyle(DS.Status.text(DS.Status.flaky))
        case .alwaysFails:
            Label("Fails every time: re-record if the change is intended, otherwise it is a regression.", systemImage: "lightbulb")
                .foregroundStyle(.secondary)
        case .passes:
            Label("Did not reproduce in the flakiness check.", systemImage: "lightbulb")
                .foregroundStyle(.secondary)
        case nil:
            if item.historyFlaky != nil {
                Label("Both passed and failed on the same commit in earlier runs.", systemImage: "lightbulb")
                    .foregroundStyle(DS.Status.text(DS.Status.flaky))
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
                        Text(signal.test).font(DS.Font.secondary.monospaced())
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

    /// The message's first line, without Swift Testing's "Issue recorded:" boilerplate.
    private func firstLine(_ message: String) -> String {
        let line = message.split(separator: "\n").first.map(String.init) ?? message
        let prefix = "Issue recorded: "
        return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
    }
}

struct FailureRow: View {
    var item: FailureItem
    var repositoryURL: URL
    var diagnosis: DiffDiagnosis?

    var body: some View {
        let failure = item.images.first?.failure
        let reference = item.images.first?.reference ?? item.referencePaths.first.map { repositoryURL.appendingPathComponent($0) }
        HStack(spacing: DS.Space.m) {
            Thumbnail(id: "failure:\(item.id)#\(failure?.path ?? reference?.path ?? "")") {
                (failure ?? reference).flatMap { try? Data(contentsOf: $0) }
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(item.test.name).fontWeight(.medium).lineLimit(1)
                HStack(spacing: DS.Space.xs) {
                    // One label for what's known about its flakiness: the verdict with the runs
                    // behind it, else the runs, else what earlier runs showed.
                    let runs = item.test.repetitions.count > 1
                        ? "\(item.test.failedRepetitions)/\(item.test.repetitions.count) runs failed" : nil
                    if let verdict = item.verdict {
                        VerdictTag(verdict: verdict, detail: runs)
                    } else if let runs {
                        Chip(text: runs, color: DS.Status.neutral)
                    }
                    if item.historyFlaky != nil && item.verdict != .flaky {
                        Chip(text: "Flaky in history", color: DS.Status.flaky)
                    }
                    if item.isNewReference {
                        Chip(text: "New reference", color: DS.Status.color(for: .new)).help("Recorded on this run; the next run checks it")
                    } else if let kind = diagnosis.flatMap(DiagnosisChip.init) {
                        kind
                    } else if item.verdict == nil && item.test.repetitions.count <= 1 && item.historyFlaky == nil {
                        Text(item.images.isEmpty ? "No images" : "Snapshot mismatch")
                            .font(DS.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: DS.Space.s)
            if item.timeline.count > 1 {
                HistoryStrip(points: Array(item.timeline.suffix(8)), size: .compact)
            }
        }
        .padding(.vertical, DS.Space.xxs)
        .listRowSeparator(.hidden)
    }
}

/// The kind of difference, for the ones that aren't plainly visible.
struct DiagnosisChip: View {
    var label: String
    var help: String

    init?(_ diagnosis: DiffDiagnosis) {
        switch diagnosis.kind {
        case .imperceptible: label = "Invisible"
        case .tiny: label = "Few pixels"
        case .sizeChanged: label = "Size changed"
        case .identical, .visible: return nil
        }
        help = diagnosis.summary
    }

    var body: some View {
        Chip(text: label, color: DS.Status.changed).help(help)
    }
}

/// One mark per recent run of a test, oldest on the left: passed, failed, or both (repetitions
/// disagreed). A flaky test reads as a broken pattern; a regression as a clean switch to red.
struct HistoryStrip: View {
    enum Size { case compact, regular }
    var points: [HistoryPoint]
    var size: Size
    /// Overrides the system setting (for tests).
    var differentiateWithoutColor: Bool?
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    var body: some View {
        let d: CGFloat = size == .compact ? 6 : 9
        HStack(spacing: size == .compact ? 2 : 3) {
            ForEach(points) { point in
                mark(point.result, width: d, height: d * (size == .compact ? 2 : 1.6))
                    .help(Self.describe(point))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Recent runs")
        .accessibilityValue(Self.summary(points))
    }

    /// Filled for passed. With Differentiate Without Color on, failures are hollow and mixed
    /// runs half filled, so the pattern doesn't depend on telling red from green.
    @ViewBuilder
    private func mark(_ result: HistoryPoint.Result, width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: width / 3, style: .continuous)
        let c = color(result)
        let withoutColor = differentiateWithoutColor ?? self.withoutColor
        if withoutColor && result == .failed {
            shape.strokeBorder(c, lineWidth: 1.5).frame(width: width, height: height)
        } else if withoutColor && result == .mixed {
            shape.strokeBorder(c, lineWidth: 1.5)
                .background(alignment: .bottom) { c.frame(height: height / 2) }
                .clipShape(shape)
                .frame(width: width, height: height)
        } else {
            shape.fill(c).frame(width: width, height: height)
        }
    }

    private func color(_ result: HistoryPoint.Result) -> Color {
        switch result {
        case .passed: DS.Status.passed
        case .failed: DS.Status.failed
        case .mixed: DS.Status.flaky
        }
    }

    static func summary(_ points: [HistoryPoint]) -> String {
        let passed = points.filter { $0.result == .passed }.count
        let mixed = points.filter { $0.result == .mixed }.count
        var text = "\(passed) of \(points.count) passed"
        if mixed > 0 { text += ", \(mixed) mixed" }
        return text
    }

    static func describe(_ point: HistoryPoint) -> String {
        let result = switch point.result {
        case .passed: "Passed"
        case .failed: "Failed"
        case .mixed: "Passed and failed"
        }
        let kind = switch point.kind {
        case .flakeCheck: " (flakiness check)"
        case .verify: " (verify)"
        case .imported: " (imported)"
        case .run, .record: ""
        }
        let commit = point.commit.map { " · " + $0.prefix(7) } ?? ""
        return "\(result)\(kind) · \(point.host)\(commit) · \(point.date.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct VerdictTag: View {
    var verdict: FlakeVerdict
    /// What the verdict rests on, e.g. "3/5 runs failed".
    var detail: String?

    var body: some View {
        let text = detail.map { "\(verdict.label) · \($0)" } ?? verdict.label
        switch verdict {
        case .alwaysFails: Chip(text: text, color: DS.Status.failed)
        case .flaky: Chip(text: text, color: DS.Status.flaky)
        case .passes: Chip(text: text, color: DS.Status.passed)
        }
    }
}

/// Several failures selected: what they are, and the two things to do with all of them at once.
struct BatchFailureDetail: View {
    let project: ProjectModel

    var body: some View {
        let items = project.selectedFailures
        let suites = Set(items.map(\.suite.identifier)).count
        VStack(spacing: 0) {
            PaneBar(height: DS.Bar.header) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("\(items.count) failing tests selected").font(DS.Font.heading).lineLimit(1)
                    Text("in \(suites) suite\(suites == 1 ? "" : "s")")
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.s)
                Button("Check Flakiness") { project.checkFlakiness(tests: items.map(\.id)) }
                    .fixedSize()
                    .quietControl()
                    .disabled(project.isRunning)
                    .help("Run just these tests several times and say which are flaky (\(project.store.settings.flakeIterations)×)")
                Button("Re-record \(items.count) Tests") { project.reRecord(failures: items) }
                    .primaryActionStyle()
                    .fixedSize()
                    .disabled(project.isRunning || project.environment == nil)
                    .help("Record these tests' snapshots again, then check that they pass (⇧⌘R)")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(items) { item in
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DS.Status.failed)
                                .accessibilityHidden(true)
                            Text(item.test.name).lineLimit(1)
                            Text(Breadcrumb.of(identifier: item.suite.identifier))
                                .font(DS.Font.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    Text("⌘-click to add or remove a test, ⇧-click to select a range.")
                        .font(DS.Font.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, DS.Space.s)
                }
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.Surface.content)
    }
}
