import AppKit
import SnapshotKitCore
import SwiftUI

struct ProjectView: View {
    @ObservedObject var project: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            // The Run tab shows the outcome in its own header; other tabs get a compact banner.
            if let message = project.lastMessage, !project.isRunning, project.tab != .run {
                NoticeBanner(text: message, isError: project.lastMessageIsError)
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, DS.Space.s)
                Divider()
            }
            Group {
                switch project.tab {
                case .snapshots: SnapshotsTab(project: project)
                case .run: RunTab(project: project)
                case .failures: FailuresTab(project: project)
                case .changes: ChangesTab(project: project)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(project.project.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $project.tab) {
                    ForEach(ProjectTab.allCases) { tab in
                        Text(label(for: tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Re-record Selected Test", systemImage: "camera") { project.reRecordSelection() }
                    .disabled(!project.canReRecordSelection)
                    .help("Re-record the test of the selected snapshot, change or failure (⇧⌘R)")
            }
            ToolbarItem(placement: .primaryAction) {
                if project.isRunning {
                    Button("Cancel", systemImage: "stop.fill") { project.cancel() }
                        .help("Cancel (⌘.)")
                } else {
                    Button("Run", systemImage: "play.fill") { project.runTests() }
                        .disabled(project.environment == nil)
                        .help("Run snapshot tests with the CI configuration (⌘R)")
                }
            }
        }
    }

    private func label(for tab: ProjectTab) -> String {
        switch tab {
        case .snapshots: (project.library?.files.count).map { "Snapshots (\($0))" } ?? "Snapshots"
        case .run: "Run"
        case .failures: project.failures.isEmpty ? "Failures" : "Failures (\(project.failures.count))"
        case .changes: (project.changeSet?.changes.count).map { "Changes (\($0))" } ?? "Changes"
        }
    }

    private var subtitle: String {
        let branch = project.currentBranch ?? "detached HEAD"
        return project.baseBranch.map { "\(branch) → \($0)" } ?? branch
    }
}

// MARK: - Run tab

struct RunTab: View {
    @ObservedObject var project: ProjectModel

    var body: some View {
        HSplitView {
            RunInspector(project: project)
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            VStack(spacing: 0) {
                RunStatusHeader(project: project)
                Divider()
                LogView(project: project)
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Settings-style column: what will run, where, and how it was configured.
struct RunInspector: View {
    @ObservedObject var project: ProjectModel
    @State private var baseBranch = ""
    @State private var remoteHost = ""

    var body: some View {
        Form {
            Section("Environment") { environment }

            Section {
                Picker("Scope", selection: Binding(
                    get: { project.settings.module ?? "" },
                    set: { value in project.updateSettings { $0.module = value.isEmpty ? nil : value } }
                )) {
                    Text("What CI runs").tag("")
                    if !project.modules.isEmpty { Divider() }
                    ForEach(project.modules, id: \.self) { Text($0).tag($0) }
                }
                .disabled(project.isRunning)
            } footer: {
                FormFooter("Pick a single test target to run only its snapshot tests.")
            }

            if let ctx = project.context {
                let c = project.config ?? ctx.config
                let row = { (name: String, value: String?, source: String?) in
                    // The footer names the CI files; only values from elsewhere (an override,
                    // a script) say where they came from.
                    self.row(name, value, source.flatMap { ctx.resolved.ciFiles.contains($0) ? nil : $0 })
                }
                Section {
                    row("Scheme", c.scheme, c.source(of: .scheme))
                    if let ws = c.workspace { row("Workspace", ws, c.source(of: .workspace)) }
                    if let p = c.project { row("Project", p, c.source(of: .project)) }
                    if let plan = c.testPlan { row("Test plan", plan, c.source(of: .testPlan)) }
                    if !c.onlyTesting.isEmpty { row("Only testing", c.onlyTesting.joined(separator: ", "), c.source(of: .onlyTesting)) }
                    row("Xcode", c.xcodeVersion ?? c.developerDir ?? "Selected Xcode", c.source(of: .xcodeVersion) ?? c.source(of: .developerDir))
                    row("Device", c.deviceName.map { $0 + (c.osVersion.map { " · \($0)" } ?? "") }, c.source(of: .deviceName))
                    if let wd = c.workingDirectory { row("Directory", wd, c.source(of: .workingDirectory)) }
                } header: {
                    Text("Configuration")
                } footer: {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        FormFooter(ctx.resolved.ciFiles.isEmpty ? "No CI files found." : "From " + ctx.resolved.ciFiles.joined(separator: ", ")
                                   + (ctx.resolved.overrideFile.map { " and \($0)" } ?? "") + ".")
                        ForEach(ctx.resolved.notes, id: \.self) { FormFooter($0).foregroundStyle(DS.Status.text(DS.Status.flaky)) }
                    }
                }

                Section {
                    TextField("Base branch", text: $baseBranch, prompt: Text(project.detectedBaseBranch ?? "develop"))
                        .accessibilityLabel("Base branch")
                        .onSubmit { project.updateSettings { $0.baseBranch = baseBranch.isEmpty ? nil : baseBranch } }
                    TextField("Remote host", text: $remoteHost, prompt: Text(ctx.resolved.config.remoteHost ?? "user@ci-mac"))
                        .accessibilityLabel("Remote host")
                        .onSubmit { project.updateSettings { $0.remoteHost = remoteHost.isEmpty ? nil : remoteHost } }
                } header: {
                    Text("Comparison & Remote")
                } footer: {
                    FormFooter((project.detectedBaseBranch.map { "Detected \($0) from \(ctx.config.source(of: .baseBranch) ?? "git"). " } ?? "")
                               + "Remote runs sync the working tree to that Mac over SSH and run the same command there.")
                }
            } else if let error = project.configError {
                Section("Configuration") {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(DS.Status.text(DS.Status.failed))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            baseBranch = project.settings.baseBranch ?? ""
            remoteHost = project.settings.remoteHost ?? ""
        }
    }

    @ViewBuilder
    private var environment: some View {
        if let env = project.environment {
            LabeledContent {
                Text(env.xcode.version + (env.xcode.build.map { " (\($0))" } ?? ""))
            } label: {
                Label("Xcode", systemImage: "hammer")
                if env.xcodeIsDefault { Text("Not pinned by CI") }
            }
            LabeledContent {
                Text("\(env.simulator.name) · \(env.simulator.platform) \(env.simulator.osVersion)")
            } label: {
                Label("Simulator", systemImage: "iphone")
                Text(env.simulator.state)
            }
        } else if let error = project.environmentError {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Label {
                    Text(error).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Button("Check Again") { project.validateEnvironment() }
            }
        } else if project.configError != nil {
            Text("Fix the configuration to check Xcode and the simulator.")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Text("Checking Xcode and simulator…").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ name: String, _ value: String?, _ source: String?) -> some View {
        LabeledContent {
            Text(value ?? "—")
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        } label: {
            Text(name)
            if let source, value != nil { Text(source) }
        }
    }
}

/// Outcome first, then the actions that act on it.
struct RunStatusHeader: View {
    @ObservedObject var project: ProjectModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .center, spacing: DS.Space.m) {
                statusIcon
                    .font(.title2)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    if let started = project.startedAt, project.isRunning {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text("\(project.phase.label)… · \(Self.elapsed(context.date.timeIntervalSince(started)))")
                                .monospacedDigit()
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 12)
                actions
            }

            if project.isRunning {
                if let total = project.expectedTotal, total > 0, project.phase == .testing {
                    ProgressView(value: Double(min(project.passed + project.failed + project.skipped, total)), total: Double(total))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }

            HStack(spacing: DS.Space.l) {
                Count(value: project.passed, label: "passed", symbol: "checkmark.circle.fill", color: .green)
                Count(value: project.failed, label: "failed", symbol: "xmark.circle.fill", color: .red)
                Count(value: project.skipped, label: "skipped", symbol: "minus.circle.fill", color: .secondary)
                Spacer()
                if let test = project.currentTest, project.isRunning {
                    Text(test)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(DS.Space.l)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if project.isRunning {
            ProgressView().controlSize(.small)
        } else if project.configError != nil {
            Image(systemName: "doc.badge.gearshape").foregroundStyle(DS.Status.failed)
        } else if project.environmentError != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Status.flaky)
        } else if project.lastMessageIsError || (project.lastMessage == nil && project.failed > 0) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(DS.Status.failed)
        } else if project.lastResult != nil || project.lastMessage != nil || project.passed > 0 {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(DS.Status.passed)
        } else {
            Image(systemName: "play.circle").foregroundStyle(.secondary)
        }
    }

    private var title: String {
        if project.isRunning { return project.stageLabel }
        if project.configError != nil { return "Configuration can't be read" }
        if project.environmentError != nil { return "Can't run on this Mac yet" }
        if let message = project.lastMessage { return message }
        if project.failed > 0 { return "\(project.failed) failing test\(project.failed == 1 ? "" : "s") in the last run" }
        return "Ready to run"
    }

    static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var subtitle: String {
        if project.isRunning { return project.phase.label + "…" }
        if project.configError != nil { return "Fix the problem shown on the left, then try again." }
        if project.environmentError != nil { return "Install what's missing, then check again." }
        if let result = project.lastResult {
            return (project.lastDuration.map { "Took \(Self.elapsed($0)) · " } ?? "") + result.commandLine
        }
        if let source = project.failureSource {
            return "\(source.label) on \(source.host), \(source.date.formatted(Self.dateStyle))"
        }
        return "Runs the snapshot tests exactly like CI."
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: DS.Space.s) {
            if project.isRunning {
                Button("Cancel", role: .cancel) { project.cancel() }
                    .secondaryActionStyle()
                    .keyboardShortcut(".")
            } else {
                Menu {
                    Button("Check Flakiness (\(project.store.settings.flakeIterations)×)") { project.checkFlakiness() }
                        .disabled(project.failingSuites.isEmpty || project.environment == nil)
                    Divider()
                    Section("On \(project.config?.remoteHost ?? "Remote Machine")") {
                        Button("Run Tests") { project.runRemote() }
                        Button("Re-record Failed") { project.reRecordOnRemote() }
                            .disabled(project.failingSuites.isEmpty)
                        Button("Check Flakiness") { project.checkFlakiness(remote: true) }
                            .disabled(project.failingSuites.isEmpty)
                    }
                    .disabled(!project.hasRemote)
                } label: {
                    Label("More Actions", systemImage: "ellipsis")
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Flakiness check and remote runs")
                .accessibilityLabel("More Actions")

                if project.environmentError != nil || project.configError != nil {
                    // Nothing can run; offer the one action that can help.
                    Button("Check Again") { project.reload() }
                        .primaryActionStyle()
                } else {
                    Button("Re-record Failed") { project.reRecordFailed() }
                        .secondaryActionStyle()
                        .disabled(project.failingSuites.isEmpty || project.environment == nil)
                        .help("Re-record only the failing suites, then verify (⇧⌘R)")
                    Button("Run Tests") { project.runTests() }
                        .primaryActionStyle()
                        .keyboardShortcut("r")
                        .disabled(project.environment == nil)
                }
            }
        }
        .controlSize(.regular)
    }
}

/// Leading-aligned section footer (grouped forms otherwise trail-align multi-line text).
struct FormFooter: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Count: View {
    // Read as "12 passed".
    var value: Int
    var label: String
    var symbol: String
    var color: Color

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: symbol)
                .foregroundStyle(value > 0 ? color : Color.secondary.opacity(0.5))
            Text("\(value)").font(.body.monospacedDigit().weight(.medium))
            Text(label).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

struct LogView: View {
    @ObservedObject var project: ProjectModel

    var body: some View {
        let lines = project.visibleLog
        let suites = project.resultSuites
        let showResults = !suites.isEmpty && project.runPane == .results
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                if suites.isEmpty {
                    Text("Output").font(.subheadline.weight(.semibold))
                } else {
                    Picker("Show", selection: $project.runPane) {
                        ForEach(RunPane.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    .accessibilityLabel("Show Results or Output")
                }
                let testCount = suites.reduce(0) { $0 + $1.tests.count }
                Text(showResults ? "\(testCount) test\(testCount == 1 ? "" : "s")" : "\(lines.count) line\(lines.count == 1 ? "" : "s")")
                    .font(DS.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                SearchField(prompt: showResults ? "Filter tests" : "Filter output", text: $project.logFilter)
                    .frame(maxWidth: 220)
                    .controlSize(.small)
                if !showResults {
                    Toggle("Build output", isOn: $project.showFullLog)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help("Include compiler and linker output")
                }
                Button {
                    let text = showResults ? RunResultsList.plainText(suites) : lines.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label(showResults ? "Copy Results" : "Copy Output", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(showResults ? false : lines.isEmpty)
                .help(showResults ? "Copy the results as text, e.g. for a merge request" : "Copy the visible output")
                .accessibilityLabel(showResults ? "Copy Results" : "Copy Output")
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            Divider()
            if showResults {
                RunResultsList(project: project, suites: suites)
            } else {
                output(lines)
            }
        }
    }

    private func output(_ lines: [String]) -> some View {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.m)
                }
                .overlay {
                    if lines.isEmpty {
                        ContentUnavailableView(
                            project.isRunning ? "Waiting for output" : "No output yet",
                            systemImage: "text.alignleft",
                            description: Text(project.isRunning ? "xcodebuild is starting…" : "Output from the next run appears here.")
                        )
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: lines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottomLeading) }
                }
            }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("✘") || line.contains(": error: ") || line.hasPrefix("** TEST FAILED") || line.hasPrefix("** BUILD FAILED") { return .red }
        if line.hasPrefix("✔") || line.hasPrefix("** TEST SUCCEEDED") { return .green }
        if line.hasPrefix("$ ") || line.hasPrefix("snapkit:") { return .accentColor }
        if line.hasPrefix("◇") || line.hasPrefix("↳") { return .primary }
        return .secondary
    }
}

/// The last run's tests by suite, failing suites first. Failed tests open on the Failures tab.
struct RunResultsList: View {
    @ObservedObject var project: ProjectModel
    var suites: [SuiteResult]

    var body: some View {
        let query = project.logFilter.trimmingCharacters(in: .whitespaces)
        let shown = suites
            .map { suite in
                (suite, query.isEmpty ? suite.tests : suite.tests.filter {
                    $0.name.localizedCaseInsensitiveContains(query) || suite.identifier.localizedCaseInsensitiveContains(query)
                })
            }
            .filter { !$0.1.isEmpty }
            .sorted { ($0.0.isFailing ? 0 : 1, $0.0.identifier) < ($1.0.isFailing ? 0 : 1, $1.0.identifier) }
        List {
            ForEach(shown, id: \.0.id) { suite, tests in
                Section {
                    ForEach(tests, id: \.identifier) { test in
                        row(test, suite: suite)
                    }
                } header: {
                    HStack {
                        Text(suite.identifier)
                        Spacer()
                        if suite.failedCount > 0 {
                            Text("\(suite.failedCount) failed").foregroundStyle(DS.Status.text(DS.Status.failed))
                        }
                        Text("\(suite.passedCount) passed").monospacedDigit()
                    }
                }
            }
        }
        .overlay {
            if shown.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    /// One line per test, failures first, for pasting into a merge request or chat.
    static func plainText(_ suites: [SuiteResult]) -> String {
        suites.sorted { ($0.isFailing ? 0 : 1, $0.identifier) < ($1.isFailing ? 0 : 1, $1.identifier) }
            .flatMap { suite in
                suite.tests.map { test in
                    let mark = switch test.outcome { case .passed: "✔"; case .failed: "✘"; default: "–" }
                    let reps = test.repetitions.count > 1 ? " (\(test.passedRepetitions)/\(test.repetitions.count) passed)" : ""
                    return "\(mark) \(suite.identifier)/\(test.name)\(reps)"
                }
            }
            .joined(separator: "\n")
    }

    private func row(_ test: TestCaseResult, suite: SuiteResult) -> some View {
        let id = suite.identifier + "/" + test.name
        let canOpen = project.failures.contains { $0.id == id }
        return HStack(spacing: DS.Space.s) {
            Image(systemName: icon(test.outcome))
                .foregroundStyle(color(test.outcome))
                .accessibilityLabel(test.outcome.rawValue)
            Text(test.name).lineLimit(1)
            if test.repetitions.count > 1 {
                Chip(text: "\(test.passedRepetitions)/\(test.repetitions.count) passed",
                     color: test.failedRepetitions > 0 && test.passedRepetitions > 0 ? DS.Status.flaky : DS.Status.neutral)
            }
            Spacer()
            if let duration = test.duration {
                Text(Duration.seconds(duration).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 1)))
                    .font(DS.Font.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if canOpen {
                Button { project.showFailure(id) } label: { Image(systemName: "arrow.forward.circle") }
                    .buttonStyle(.borderless)
                    .help("Compare on the Failures tab")
                    .accessibilityLabel("Show Failure")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if canOpen { project.showFailure(id) } }
    }

    private func icon(_ outcome: TestOutcome) -> String {
        switch outcome {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "minus.circle.fill"
        case .expectedFailure: "checkmark.circle.badge.xmark"
        case .unknown: "questionmark.circle"
        }
    }

    private func color(_ outcome: TestOutcome) -> Color {
        switch outcome {
        case .passed: DS.Status.passed
        case .failed: DS.Status.failed
        case .skipped, .expectedFailure, .unknown: DS.Status.neutral
        }
    }
}
