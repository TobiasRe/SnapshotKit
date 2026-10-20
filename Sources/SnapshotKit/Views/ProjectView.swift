import AppKit
import SnapshotKitCore
import SwiftUI

struct ProjectView: View {
    @Bindable var project: ProjectModel
    /// The message the user closed (or that timed out); a new message shows again.
    @State private var dismissedMessage: String?

    var body: some View {
        Group {
            switch project.tab {
            case .snapshots: SnapshotsTab(project: project)
            case .run: RunTab(project: project)
            case .failures: FailuresTab(project: project)
            case .changes: ChangesTab(project: project)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Snapshot files are watched; commits and branch switches made elsewhere are picked up
        // when you come back to the app, on any tab.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !project.isRunning { project.refreshChanges() }
        }
        // The outcome of the last action floats over the image area (above the compare toolbar)
        // instead of pushing every pane down. The Run tab says it in its own header.
        .overlay(alignment: .bottomTrailing) {
            if let message = project.lastMessage, message != dismissedMessage, !project.isRunning, project.tab != .run {
                NoticeBanner(text: message, isError: project.lastMessageIsError,
                             action: project.lastMessageAction.flatMap { action in
                                 // No need to offer the tab you're on.
                                 action.tab == project.tab ? nil : (action.title, {
                                     dismissedMessage = message
                                     project.tab = action.tab
                                 })
                             },
                             onClose: { dismissedMessage = message })
                    .frame(maxWidth: 420)
                    .floatingGlass(in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                    .padding(.bottom, 64)
                    .padding(.trailing, DS.Space.l)
                    .transition(.opacity)
                    .task(id: message) {
                        // Information fades; an error stays until it is closed.
                        guard !project.lastMessageIsError, !DS.solidSurfaces else { return }
                        try? await Task.sleep(for: .seconds(8))
                        withAnimation(DS.motion) { dismissedMessage = message }
                    }
            }
        }
        .confirmationDialog("Re-record all \(ProjectModel.testCount(project.recordableSnapshots)) snapshot tests?",
                            isPresented: $project.confirmReRecordAll) {
            Button("Re-record All") { project.reRecordAll() }
        } message: {
            Text("Every reference image is recorded again and then verified. Review the result on the Changes tab before committing.")
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
                    // Run, with the two bulk re-records one click away under its chevron.
                    Menu {
                        Button("Re-record Failing Tests", systemImage: "camera.badge.ellipsis") { project.reRecordFailed() }
                            .disabled(project.failingSuites.isEmpty)
                        Button("Re-record All Snapshot Tests…", systemImage: "camera.on.rectangle") { project.confirmReRecordAll = true }
                            .disabled(project.recordableSnapshots.isEmpty)
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    } primaryAction: {
                        project.runTests()
                    }
                    .disabled(project.environment == nil)
                    .help("Run snapshot tests with the CI configuration (⌘R); the arrow re-records failed or all snapshot tests")
                }
            }
        }
    }

    private func label(for tab: ProjectTab) -> String {
        switch tab {
        // A count only when there is something to count: "Changes (0)" is noise.
        case .snapshots: Self.counted("Snapshots", project.library?.files.count)
        case .run: "Run"
        case .failures: Self.counted("Failures", project.failures.count)
        case .changes: Self.counted("Changes", project.changeSet?.changes.count)
        }
    }

    static func counted(_ title: String, _ count: Int?) -> String {
        guard let count, count > 0 else { return title }
        return "\(title) (\(count))"
    }

    private var subtitle: String {
        let branch = project.currentBranch ?? "detached HEAD"
        // "feature → develop" says what Changes compares; on the base branch itself just its name.
        guard let base = project.baseBranch, base != branch else { return branch }
        return "\(branch) → \(base)"
    }
}

// MARK: - Run tab

struct RunTab: View {
    let project: ProjectModel

    var body: some View {
        ListDetailSplit(minWidth: 300) {
            RunInspector(project: project)
        } detail: {
            VStack(spacing: 0) {
                RunStatusHeader(project: project)
                Divider()
                LogView(project: project)
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// What will run, where, and how it was configured: a compact property list, labels in one
/// column and values in the next, like an inspector.
struct RunInspector: View {
    let project: ProjectModel
    @State private var baseBranch = ""
    @State private var remoteHost = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                PropertySection("Environment") { environment }

                PropertySection("Scope", footer: "Pick a single test target to run only its snapshot tests.") {
                    PropertyRow("Test target", alignment: .center) {
                        // A glass menu like the Changes filters, not a system pop-up button.
                        Menu {
                            Picker("Test target", selection: Binding(
                                get: { project.settings.module ?? "" },
                                set: { value in project.updateSettings { $0.module = value.isEmpty ? nil : value } }
                            )) {
                                Text("What CI runs").tag("")
                                if !project.modules.isEmpty { Divider() }
                                ForEach(project.modules, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            Text(project.settings.module ?? "What CI runs")
                        }
                        .fixedSize()
                        .quietControl()
                        .disabled(project.isRunning)
                        .accessibilityLabel("Test target")
                    }
                }

                if let ctx = project.context {
                    let c = project.config ?? ctx.config
                    let source = { (field: SnapshotConfig.Field) in
                        // The footer names the CI files; only values from elsewhere (an override,
                        // a script) say where they came from.
                        c.source(of: field).flatMap { ctx.resolved.ciFiles.contains($0) ? nil : $0 }
                    }
                    PropertySection("Configuration", footer: (ctx.resolved.ciFiles.isEmpty ? "No CI files found." : "From " + ctx.resolved.ciFiles.joined(separator: ", ")
                                                              + (ctx.resolved.overrideFile.map { " and \($0)" } ?? "") + "."),
                                    notes: ctx.resolved.notes) {
                        PropertyRow("Scheme", value: c.scheme, source: source(.scheme))
                        if let ws = c.workspace { PropertyRow("Workspace", value: ws, source: source(.workspace)) }
                        if let p = c.project { PropertyRow("Project", value: p, source: source(.project)) }
                        if let plan = c.testPlan { PropertyRow("Test plan", value: plan, source: source(.testPlan)) }
                        if !c.onlyTesting.isEmpty { PropertyRow("Only testing", value: c.onlyTesting.joined(separator: ", "), source: source(.onlyTesting)) }
                        PropertyRow("Xcode", value: c.xcodeVersion ?? c.developerDir ?? "Selected Xcode", source: source(.xcodeVersion) ?? source(.developerDir))
                        PropertyRow("Device", value: c.deviceName.map { $0 + (c.osVersion.map { " · \($0)" } ?? "") }, source: source(.deviceName))
                        if let wd = c.workingDirectory { PropertyRow("Directory", value: wd, source: source(.workingDirectory)) }
                    }

                    PropertySection("Comparison & Remote",
                                    footer: (project.detectedBaseBranch.map { "Detected \($0) from \(ctx.config.source(of: .baseBranch) ?? "git"). " } ?? "")
                                        + "Remote runs sync the working tree to that Mac over SSH and run the same command there.") {
                        PropertyRow("Base branch", alignment: .center) {
                            TextField("Base branch", text: $baseBranch, prompt: Text(project.detectedBaseBranch ?? "develop"))
                                .textFieldStyle(.plain)
                                .fieldChrome()
                                .accessibilityLabel("Base branch")
                                .onSubmit { project.updateSettings { $0.baseBranch = baseBranch.isEmpty ? nil : baseBranch } }
                        }
                        PropertyRow("Remote host", alignment: .center) {
                            TextField("Remote host", text: $remoteHost, prompt: Text(ctx.resolved.config.remoteHost ?? "user@ci-mac"))
                                .textFieldStyle(.plain)
                                .fieldChrome()
                                .accessibilityLabel("Remote host")
                                .onSubmit { project.updateSettings { $0.remoteHost = remoteHost.isEmpty ? nil : remoteHost } }
                        }
                    }
                } else if let error = project.configError {
                    PropertySection("Configuration") {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(DS.Status.text(DS.Status.failed))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
        .background(DS.Surface.content)
        .onAppear {
            baseBranch = project.settings.baseBranch ?? ""
            remoteHost = project.settings.remoteHost ?? ""
        }
    }

    @ViewBuilder
    private var environment: some View {
        if let env = project.environment {
            PropertyRow("Xcode", value: env.xcode.version + (env.xcode.build.map { " (\($0))" } ?? ""),
                        source: env.xcodeIsDefault ? "Not pinned by CI" : nil)
            PropertyRow("Simulator", value: "\(env.simulator.name) · \(env.simulator.platform) \(env.simulator.osVersion)",
                        source: env.simulator.state)
        } else if let error = project.environmentError {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Label {
                    Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Status.flaky)
                }
                Button("Check Again") { project.validateEnvironment() }
                    .quietControl()
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
}

/// A group of properties under a small header, with an optional note below.
struct PropertySection<Content: View>: View {
    var title: String
    var footer: String?
    var notes: [String] = []
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil, notes: [String] = [], @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.notes = notes
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title)
                .font(DS.Font.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: DS.Space.xs) { content }
            if let footer { FormFooter(footer).padding(.top, DS.Space.xxs) }
            ForEach(notes, id: \.self) { FormFooter($0).foregroundStyle(DS.Status.text(DS.Status.flaky)) }
        }
        .font(DS.Font.secondary)
    }
}

/// One property: a label in a fixed column, its value beside it, and where the value came from
/// in quieter type when that isn't obvious.
struct PropertyRow<Value: View>: View {
    var label: String
    var source: String?
    /// Text values align on their baseline; controls (fields, pickers) on their centre, as a text
    /// field's baseline moves when it gains or loses focus.
    var alignment: VerticalAlignment = .firstTextBaseline
    @ViewBuilder var value: Value

    static var labelWidth: CGFloat { 104 }

    init(_ label: String, source: String? = nil, alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder value: () -> Value) {
        self.label = label
        self.source = source
        self.alignment = alignment
        self.value = value()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: DS.Space.m) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                value
                if let source {
                    Text(source).font(DS.Font.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 24)
    }
}

extension PropertyRow where Value == PropertyValue {
    init(_ label: String, value: String?, source: String? = nil) {
        self.init(label, source: value == nil ? nil : source) { PropertyValue(text: value ?? "—") }
    }
}

/// A property's value as text people can select and copy.
struct PropertyValue: View {
    var text: String
    var body: some View { Text(text).textSelection(.enabled) }
}

/// Outcome first, then the actions that act on it.
struct RunStatusHeader: View {
    let project: ProjectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The outcome and what to do about it, in the same header bar as every other pane.
            HStack(alignment: .center, spacing: DS.Space.m) {
                statusIcon
                    .font(.title3)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title)
                        .font(DS.Font.heading)
                        .lineLimit(1)
                    Group {
                        if let started = project.startedAt, project.isRunning {
                            TimelineView(.periodic(from: started, by: 1)) { context in
                                Text("\(project.phase.label)… · \(Self.elapsed(context.date.timeIntervalSince(started)))")
                                    .monospacedDigit()
                            }
                        } else {
                            Text(subtitle)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.m)
                actions
            }
            .padding(.horizontal, DS.Space.l)
            .frame(maxWidth: .infinity, minHeight: DS.Bar.header, maxHeight: DS.Bar.header)
            // Progress runs along the bar's bottom edge, so starting a run moves nothing.
            .overlay(alignment: .bottom) {
                if project.isRunning {
                    Group {
                        if let total = project.expectedTotal, total > 0, project.phase == .testing {
                            ProgressView(value: Double(min(project.passed + project.failed + project.skipped, total)), total: Double(total))
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                    }
                    .controlSize(.mini)
                    .padding(.horizontal, DS.Space.l)
                }
            }

            HStack(spacing: DS.Space.l) {
                if hasCounts {
                    Count(value: project.passed, label: "passed", symbol: "checkmark.circle.fill", color: DS.Status.passed)
                    Count(value: project.failed, label: "failed", symbol: "xmark.circle.fill", color: DS.Status.failed)
                    Count(value: project.skipped, label: "skipped", symbol: "minus.circle.fill", color: DS.Status.neutral)
                } else {
                    // Three zeros say nothing; say that instead, in the same place.
                    Text("No results yet").foregroundStyle(.tertiary)
                }
                Spacer(minLength: DS.Space.s)
                if let test = project.currentTest, project.isRunning {
                    Text(test)
                        .font(DS.Font.code)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(DS.Font.secondary)
            .padding(.horizontal, DS.Space.l)
            .frame(maxWidth: .infinity, minHeight: DS.Bar.filters, maxHeight: DS.Bar.filters)
            .padding(.bottom, DS.Space.xs)
        }
        .background(DS.Surface.content)
    }

    private var hasCounts: Bool {
        project.isRunning || project.passed + project.failed + project.skipped > 0 || project.lastResult != nil
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
                    .fixedSize()
                    .quietControl()
                    .keyboardShortcut(".")
            } else {
                GlassIconMenu(title: "More Actions", symbol: "ellipsis", help: "Re-record everything, flakiness check and remote runs") {
                    Button("Re-record All Snapshot Tests…") { project.confirmReRecordAll = true }
                        .disabled(project.recordableSnapshots.isEmpty || project.environment == nil)
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
                }

                if project.environmentError != nil || project.configError != nil {
                    // Nothing can run; offer the one action that can help.
                    Button("Check Again") { project.reload() }
                        .primaryActionStyle()
                        .fixedSize()
                } else {
                    Button("Re-record Failed") { project.reRecordFailed() }
                        .fixedSize()
                        .quietControl()
                        .disabled(project.failingSuites.isEmpty || project.environment == nil)
                        .help("Re-record the failing suites of the last run, then verify (⌥⇧⌘R)")
                    Button("Run Tests") { project.runTests() }
                        .primaryActionStyle()
                        .fixedSize()
                        .keyboardShortcut("r")
                        .disabled(project.environment == nil)
                }
            }
        }
        .controlSize(.small)
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
            Text("\(value)").monospacedDigit().fontWeight(.medium)
            Text(label).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

struct LogView: View {
    @Bindable var project: ProjectModel

    var body: some View {
        let lines = project.visibleLog
        let suites = project.resultSuites
        let showResults = !suites.isEmpty && project.runPane == .results
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                if suites.isEmpty {
                    Text("Output").font(DS.Font.caption.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    GlassSegmented(title: "Show Results or Output",
                                   segments: RunPane.allCases.map { Segment($0.rawValue, value: $0) },
                                   selection: $project.runPane)
                        .fixedSize()
                }
                let testCount = suites.reduce(0) { $0 + $1.tests.count }
                Text(showResults ? "\(testCount) test\(testCount == 1 ? "" : "s")" : "\(lines.count) line\(lines.count == 1 ? "" : "s")")
                    .font(DS.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                SearchField(prompt: showResults ? "Filter tests" : "Filter output", text: $project.logFilter,
                            focusRequest: project.focusFilterRequest)
                    .frame(maxWidth: 220)
                    .controlSize(.small)
                if !showResults {
                    // A glass toggle like Viewed, not a checkbox among glass controls.
                    Button { project.showFullLog.toggle() } label: {
                        Label("Build output", systemImage: project.showFullLog ? "checkmark.circle.fill" : "circle")
                    }
                    .foregroundStyle(project.showFullLog ? .primary : .secondary)
                    .fixedSize()
                    .quietControl()
                    .controlSize(.small)
                    .help("Include compiler and linker output")
                    .accessibilityLabel("Build output")
                    .accessibilityValue(project.showFullLog ? "On" : "Off")
                    .accessibilityAddTraits(project.showFullLog ? .isSelected : [])
                }
                GlassIconButton(title: showResults ? "Copy Results" : "Copy Output", symbol: "doc.on.doc",
                                help: showResults ? "Copy the results as text, e.g. for a merge request" : "Copy the visible output") {
                    let text = showResults ? RunResultsList.plainText(suites) : lines.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(showResults ? false : lines.isEmpty)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(maxWidth: .infinity, minHeight: DS.Bar.filters, maxHeight: DS.Bar.filters)
            .background(DS.Surface.content)
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
                        let terms = project.logFilter.lowercased().split(separator: " ").map(String.init)
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(Self.highlighted(line, terms: terms))
                                .font(DS.Font.log)
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

    /// The line with what the filter matched marked, as find does.
    static func highlighted(_ line: String, terms: [String]) -> AttributedString {
        var text = AttributedString(line)
        let lower = line.lowercased()
        // Offsets are counted in the lowercased line; skip the rare line whose length lowercasing changes.
        guard !terms.isEmpty, lower.count == line.count else { return text }
        for term in terms where !term.isEmpty {
            var search = lower.startIndex
            while let range = lower.range(of: term, range: search..<lower.endIndex) {
                let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let length = lower.distance(from: range.lowerBound, to: range.upperBound)
                let from = text.index(text.startIndex, offsetByCharacters: start)
                let to = text.index(from, offsetByCharacters: length)
                text[from..<to].backgroundColor = Color.yellow.opacity(0.35)
                search = range.upperBound
            }
        }
        return text
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
    let project: ProjectModel
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
                    HStack(spacing: DS.Space.s) {
                        Text(suite.identifier.split(separator: "/").joined(separator: " › ")).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: DS.Space.s)
                        if suite.failedCount > 0 {
                            Text("\(suite.failedCount) failed").foregroundStyle(DS.Status.text(DS.Status.failed))
                        }
                        Text("\(suite.passedCount) passed").foregroundStyle(.tertiary)
                    }
                    .monospacedDigit()
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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
        .listRowSeparator(.hidden)
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
