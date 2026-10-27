import AppKit
import SnapshotKitCore
import SwiftUI

struct ProjectView: View {
    @Bindable var project: ProjectModel
    /// The message the user closed (or that timed out); a new message shows again.
    /// The `messageID` of the notice that was closed or faded.
    @State private var dismissedMessage: Int?

    var body: some View {
        Group {
            switch project.section.content {
            case .snapshots: SnapshotsTab(project: project)
            case .run: RunTab(project: project)
            case .failures: FailuresTab(project: project)
            case .changes: ChangesTab(project: project)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Snapshot files are watched; commits, branch switches and runs of `snapkit` made elsewhere
        // are picked up when you come back to the app, in any section.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            project.refreshAfterActivation()      // skips itself while a run is going on
        }
        // The outcome of the last action floats over the image area (above the compare toolbar)
        // instead of pushing every pane down. The Run view says it in its own header.
        .overlay(alignment: .bottomTrailing) {
            if let message = project.lastMessage, project.messageID != dismissedMessage, !project.isRunning, project.section != .run {
                let id = project.messageID
                NoticeBanner(text: message, isError: project.lastMessageIsError,
                             action: project.lastMessageAction.flatMap { action in
                                 // No need to offer the section you're in.
                                 let section = action.section
                                 return section == project.section ? nil : (action.title, {
                                     dismissedMessage = id
                                     project.section = section
                                 })
                             },
                             onClose: { dismissedMessage = id })
                    .frame(maxWidth: DS.Pane.readableWidth)
                    .floatingGlass(in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
                    .padding(.bottom, 64)
                    .padding(.trailing, DS.Space.l)
                    .transition(.opacity)
                    .task(id: id) {
                        // Information fades; an error stays until it is closed.
                        guard !project.lastMessageIsError, !DS.solidSurfaces else { return }
                        // Not when the notice was replaced meanwhile (the sleep throws on cancel).
                        guard (try? await Task.sleep(for: .seconds(8))) != nil else { return }
                        withAnimation(DS.motion) { dismissedMessage = id }
                    }
            }
        }
        .confirmationDialog(ProjectModel.testCount(project.recordableSnapshots) == 1 ? "Re-record the snapshot test?"
                            : "Re-record all \(ProjectModel.testCount(project.recordableSnapshots)) snapshot tests?",
                            isPresented: $project.confirmReRecordAll) {
            Button(ProjectModel.testCount(project.recordableSnapshots) == 1 ? "Re-record" : "Re-record All") { project.reRecordAll() }
        } message: {
            Text("Every reference image is recorded again and then verified. Review the result in Working copy before committing.")
        }
        // The sidebar says which project and section; the title repeats the section, as a Mac
        // window names what it shows, and the subtitle where it is.
        .navigationTitle(project.title(of: project.section))
        .navigationSubtitle(subtitle)
        .toolbar {
            // No re-record button here: each detail header has one beside what it records, and ⇧⌘R
            // works from anywhere.
            ToolbarItem(placement: .primaryAction) {
                if project.isRunning {
                    Button("Cancel", systemImage: "stop.fill") { project.cancel() }
                        .help("Cancel (⌘.)")
                } else {
                    // Run, with the two bulk re-records one click away under its chevron.
                    Menu {
                        Button("Re-record Failing Suites", systemImage: "camera.badge.ellipsis") { project.reRecordFailed() }
                            .disabled(project.failingSuites.isEmpty)
                        Button("Re-record All Snapshot Tests…", systemImage: "camera.on.rectangle") { project.confirmReRecordAll = true }
                            .disabled(project.recordableSnapshots.isEmpty)
                    } label: {
                        Label {
                            Text("Run")
                        } icon: {
                            Image(systemName: "play.fill")
                        }
                    } primaryAction: {
                        project.runTests()
                    }
                    .disabled(project.environment == nil)
                    .help("Run snapshot tests with the CI configuration (⌘R); the arrow re-records failed or all snapshot tests")
                    .accessibilityLabel("Run Snapshot Tests")
                }
            }
        }
    }

    /// "Shop · feature/checkout-redesign": the project, and the branch checked out.
    private var subtitle: String {
        guard let branch = project.branchLabel else { return project.project.name }
        return "\(project.project.name) · \(branch)"
    }
}

// MARK: - Run

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
    @State private var ciLogin = ""
    private enum Field { case baseBranch, remoteHost, ciLogin }
    @FocusState private var focused: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                PropertySection("Environment") { environment }

                PropertySection("Scope") {
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
                        .help("Run the snapshot tests of one test target only")
                    }
                }

                if let ctx = project.context {
                    let c = project.config ?? ctx.config
                    let source = { (field: SnapshotConfig.Field) in
                        // The footer names the CI files; only values from elsewhere (an override,
                        // a script) say where they came from.
                        c.source(of: field).flatMap { ctx.resolved.ciFiles.contains($0) ? nil : $0 }
                    }
                    PropertySection("Configuration", footer: (ctx.resolved.ciFiles.isEmpty ? "No CI files found." : "From " + ctx.resolved.ciFiles.map { "`\($0)`" }.joined(separator: ", ")
                                                              + (ctx.resolved.overrideFile.map { " and `\($0)`" } ?? "") + "."),
                                    notes: ctx.resolved.notes) {
                        PropertyRow("Scheme", value: c.scheme, source: source(.scheme), code: true)
                        if let ws = c.workspace { PropertyRow("Workspace", value: ws, source: source(.workspace), code: true) }
                        if let p = c.project { PropertyRow("Project", value: p, source: source(.project), code: true) }
                        if let plan = c.testPlan { PropertyRow("Test plan", value: plan, source: source(.testPlan), code: true) }
                        if !c.onlyTesting.isEmpty { PropertyRow("Only testing", value: c.onlyTesting.joined(separator: ", "), source: source(.onlyTesting), code: true) }
                        // Once found, Environment shows the Xcode and simulator in use; until then, what's asked for.
                        if project.environment == nil {
                            PropertyRow("Xcode", value: c.xcodeVersion ?? c.developerDir ?? "Selected Xcode", source: source(.xcodeVersion) ?? source(.developerDir))
                            PropertyRow("Device", value: c.deviceName.map { $0 + (c.osVersion.map { " · \($0)" } ?? "") }, source: source(.deviceName))
                        }
                        if let wd = c.workingDirectory { PropertyRow("Directory", value: wd, source: source(.workingDirectory), code: true) }
                    }

                    PropertySection("Comparison & Remote",
                                    footer: project.detectedBaseBranch.map { "Detected `\($0)` from `\(ctx.config.source(of: .baseBranch) ?? "git")`." }) {
                        PropertyRow("Base branch", alignment: .center) {
                            TextField("", text: $baseBranch)
                                .textFieldStyle(.plain)
                                .placeholder(project.detectedBaseBranch ?? "develop", shown: baseBranch.isEmpty)
                                .fieldChrome()
                                .accessibilityLabel("Base branch")
                                .focused($focused, equals: .baseBranch)
                                .onSubmit(saveFields)
                        }
                        PropertyRow("Remote host", alignment: .center) {
                            TextField("", text: $remoteHost)
                                .textFieldStyle(.plain)
                                .placeholder(ctx.resolved.config.remoteHost ?? "user@ci-mac", shown: remoteHost.isEmpty)
                                .fieldChrome()
                                .accessibilityLabel("Remote host")
                                .help("Remote runs sync the working tree to this Mac over SSH and run the same command there")
                                .focused($focused, equals: .remoteHost)
                                .onSubmit(saveFields)
                        }
                        PropertyRow("CI login", alignment: .center) {
                            TextField("", text: $ciLogin)
                                .textFieldStyle(.plain)
                                // A hint, not a value: a name here read as one already set.
                                .placeholder("user, or user@host", shown: ciLogin.isEmpty)
                                .fieldChrome()
                                .accessibilityLabel("CI login")
                                .help("The SSH login on CI runners, to copy the images a failed job’s tests took. "
                                      + "Empty: ssh’s default, or ~/.ssh/config.")
                                .focused($focused, equals: .ciLogin)
                                .onSubmit(saveFields)
                        }
                    }
                } else if let error = project.configError {
                    PropertySection("Configuration") {
                        StatusNote(error, symbol: "xmark.circle.fill", color: DS.Status.failed)
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
            ciLogin = project.settings.ciLogin ?? ""
        }
        // Saved like any Mac field: on Return, and also when you click or tab away or leave the view.
        .onChange(of: focused) { saveFields() }
        // A host also once you stop typing, so the ··· menu's remote section works without leaving the
        // field. (Not the base branch: a half-typed one would flash "not found" in the changes.)
        .task(id: remoteHost) {
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            saveFields()
        }
        .onDisappear(perform: saveFields)
    }

    /// Stores what the fields say, if it differs from the settings (a save reloads the configuration).
    private func saveFields() {
        if (ciLogin.isEmpty ? nil : ciLogin) != project.settings.ciLogin { project.setCILogin(ciLogin) }
        let base = baseBranch.isEmpty ? nil : baseBranch, host = remoteHost.isEmpty ? nil : remoteHost
        guard base != project.settings.baseBranch || host != project.settings.remoteHost else { return }
        project.updateSettings {
            $0.baseBranch = base
            $0.remoteHost = host
        }
    }

    @ViewBuilder
    private var environment: some View {
        if let env = project.environment {
            PropertyRow("Xcode", value: env.xcode.version + (env.xcode.build.map { " (\($0))" } ?? ""),
                        source: env.xcodeIsDefault ? "Not pinned by CI" : nil)
            PropertyRow("Simulator", value: "\(env.simulator.name) · \(env.simulator.platform) \(env.simulator.osVersion)",
                        source: env.simulator.state)
            // What the check had to decide, e.g. a `developerDir` Xcode other than the version CI pins.
            ForEach(project.environmentNotes, id: \.self) { note in
                StatusNote(note, symbol: "info.circle", color: .secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let error = project.environmentError {
            // The header's Check Again is the way on; one button for it is enough.
            StatusNote(error, symbol: "exclamationmark.triangle.fill", color: DS.Status.flaky)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
            ForEach(notes, id: \.self) { note in
                StatusNote(note, symbol: "exclamationmark.triangle.fill", color: DS.Status.flaky)
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, DS.Space.xxs)
            }
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
                    Text(source).font(DS.Font.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 24)
    }
}

extension PropertyRow where Value == PropertyValue {
    /// `code`: an identifier (a scheme, a file, a path), set in monospaced type at the row's size.
    init(_ label: String, value: String?, source: String? = nil, code: Bool = false) {
        self.init(label, source: value == nil ? nil : source) { PropertyValue(text: value ?? "—", code: code && value != nil) }
    }
}

/// A property's value as text people can select and copy.
struct PropertyValue: View {
    var text: String
    var code = false
    var body: some View {
        if code {
            // A name on one line, cut in the middle: wrapped, "Sample-App" broke at its hyphen and
            // read as two words. The whole of it is in the tooltip.
            Text(text).fontDesign(.monospaced).lineLimit(1).truncationMode(.middle).help(text).textSelection(.enabled)
        } else {
            Text(text).textSelection(.enabled)
        }
    }
}

/// Outcome first, then the actions that act on it.
struct RunStatusHeader: View {
    let project: ProjectModel
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The outcome and what to do about it, in the same header bar as every other pane. When
            // the title and every button don't fit, Re-record moves into the menu before the title cuts.
            ViewThatFits(in: .horizontal) {
                row(compact: false)
                row(compact: true)
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
                    // Most runs skip nothing; a count of zero would only add noise.
                    if project.skipped > 0 {
                        Count(value: project.skipped, label: "skipped", symbol: "minus.circle.fill", color: DS.Status.neutral)
                    }
                } else {
                    // Three zeros say nothing; say that instead, in the same place.
                    Text("No results yet").foregroundStyle(.secondary)
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

    private func row(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            statusIcon
                .font(.title3)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(StatusNote.code(title, font: DS.Font.heading.monospaced()))
                    .font(DS.Font.heading)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
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
                            .help(project.isRunning ? "" : project.lastResult?.commandLine ?? "")
                    }
                }
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.m)
            actions(compact: compact)
        }
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
        } else if project.lastMessageIsCancellation {
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        } else if project.lastMessageIsError || (project.lastMessage == nil && project.failed > 0) {
            // The same marks as a test's row: failed and passed are circles everywhere.
            Image(systemName: "xmark.circle.fill").foregroundStyle(DS.Status.failed)
        } else if project.lastResult != nil || project.lastMessage != nil || project.passed > 0 {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Status.passed)
        } else {
            Image(systemName: "play.circle").foregroundStyle(.secondary)
        }
    }

    private var title: String {
        if project.isRunning { return project.stageLabel }
        if project.configError != nil { return "Configuration can’t be read" }
        if project.environmentError != nil { return "Can’t run on this Mac yet" }
        if let message = project.lastMessage { return message }
        if project.failed > 0 { return "\(project.failed) failing test\(project.failed == 1 ? "" : "s") in the last run" }
        return "Ready to run"
    }


    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var subtitle: String {
        if project.isRunning { return project.phase.label + "…" }
        if project.configError != nil { return "Fix the problem shown on the left, then try again." }
        if project.environmentError != nil { return "Install what’s missing, then check again." }
        // The command itself is long and cut in the middle here; it's in the tooltip and the output.
        if project.lastResult != nil, let duration = project.lastDuration {
            return "Took \(Self.elapsed(duration))"
        }
        if let source = project.failureSource {
            // As the Failures header says it: label, then where and when.
            return "\(source.label) · \(source.host) · \(source.date.formatted(DS.Dates.moment.localized(locale, timeZone)))"
        }
        return "Runs the snapshot tests exactly like CI."
    }

    /// Compact puts Re-record Failing Suites in the menu, for headers too narrow for it.
    @ViewBuilder
    private func actions(compact: Bool) -> some View {
        HStack(spacing: DS.Space.s) {
            if project.isRunning {
                // ⌘. and ⌘R belong to the Snapshots menu; a second binding here would compete with it.
                Button("Cancel", role: .cancel) { project.cancel() }
                    .fixedSize()
                    .quietControl()
                    .help("Cancel the run (⌘.)")
            } else {
                GlassIconMenu(title: "More Actions", symbol: "ellipsis", help: "Re-record everything, flakiness check and remote runs") {
                    if compact && !hasProblem {
                        reRecordFailed.disabled(!canReRecordFailed)
                    }
                    Button("Re-record All Snapshot Tests…") { project.confirmReRecordAll = true }
                        .disabled(project.recordableSnapshots.isEmpty || project.environment == nil)
                    Button("Check Flakiness of Failing Tests") { project.checkFlakiness() }
                        .disabled(project.failingSuites.isEmpty || project.environment == nil)
                    Divider()
                    Section("On \(project.config?.remoteHost ?? "Remote Machine")") {
                        Button("Run Tests") { project.runRemote() }
                        Button("Re-record Failing Suites") { project.reRecordOnRemote() }
                            .disabled(project.failingSuites.isEmpty)
                        Button("Check Flakiness of Failing Tests") { project.checkFlakiness(remote: true) }
                            .disabled(project.failingSuites.isEmpty)
                    }
                    .disabled(!project.hasRemote)
                }

                if hasProblem {
                    // Nothing can run; offer the one action that can help.
                    Button("Check Again") { project.reload() }
                        .primaryActionStyle()
                        .fixedSize()
                } else {
                    if !compact {
                        reRecordFailed
                            .fixedSize()
                            .quietControl()
                            .disabled(!canReRecordFailed)
                            .help("Re-record the failing suites of the last run, then verify (⌥⇧⌘R)")
                    }
                    Button("Run Tests") { project.runTests() }
                        .primaryActionStyle()
                        .fixedSize()
                        .disabled(project.environment == nil)
                        .help("Run the snapshot tests like CI (⌘R)")
                }
            }
        }
        .controlSize(.small)
    }

    private var hasProblem: Bool { project.environmentError != nil || project.configError != nil }

    private var canReRecordFailed: Bool { !project.failingSuites.isEmpty && project.environment != nil }

    /// Disable it outside its style: the quiet style dims by the enabled state around it.
    private var reRecordFailed: some View {
        Button("Re-record Failing Suites") { project.reRecordFailed() }
    }
}

/// Leading-aligned section footer (grouped forms otherwise trail-align multi-line text).
struct FormFooter: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        // Files and branches in backticks are set in code type.
        Text(StatusNote.code(text))
            .font(DS.Font.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One of the run's counts with its status icon, read as one element ("12 passed").
struct Count: View {
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
                let count = showResults ? testCount : lines.count
                // "0 lines" says nothing the empty pane doesn't.
                if count > 0 {
                    Text(showResults ? "\(count) test\(count == 1 ? "" : "s")" : "\(count) line\(count == 1 ? "" : "s")")
                        .font(DS.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                SearchField(prompt: showResults ? "Filter tests" : "Filter output", text: $project.logFilter,
                            focusRequest: project.focusFilterRequest)
                    .frame(maxWidth: 220)
                if !showResults {
                    // A glass toggle like Viewed, not a checkbox among glass controls.
                    Button { project.showFullLog.toggle() } label: {
                        Label("Build output", systemImage: project.showFullLog ? "checkmark.circle.fill" : "circle")
                    }
                    // The icon says on or off; a grey label read as disabled.
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
                        project.isRunning ? "Waiting for Output" : "No Output Yet",
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
                text[from..<to].backgroundColor = DS.Surface.match
                search = range.upperBound
            }
        }
        return text
    }

    private func color(for line: String) -> Color {
        // Text in a status color: the text variants keep 4.5:1 on the log's background.
        if line.hasPrefix("✘") || line.contains(": error: ") || line.hasPrefix("** TEST FAILED") || line.hasPrefix("** BUILD FAILED") { return DS.Status.text(DS.Status.failed) }
        if line.hasPrefix("✔") || line.hasPrefix("** TEST SUCCEEDED") { return DS.Status.text(DS.Status.passed) }
        if line.hasPrefix("$ ") || line.hasPrefix("snapkit:") { return .accentColor }
        if line.hasPrefix("◇") || line.hasPrefix("↳") { return .primary }
        return .secondary
    }
}

/// The last run's tests by suite, failing suites first. Failed tests open with the run's failures.
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
                        Text(Breadcrumb.of(identifier: suite.identifier, showingBundle: Breadcrumb.severalBundles(shown.map(\.0.identifier))))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: DS.Space.s)
                        if suite.failedCount > 0 {
                            // The dot carries the color, as a project's failing count does.
                            HStack(spacing: DS.Space.xs) {
                                Circle().fill(DS.Status.failed).frame(width: DS.Status.dot, height: DS.Status.dot)
                                Text("\(suite.failedCount) failed")
                            }
                        }
                        if suite.passedCount > 0 {
                            Text("\(suite.passedCount) passed").foregroundStyle(.secondary)
                        }
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
                    let reps = test.repetitions.count > 1 ? " (\(test.passedRepetitions) of \(test.repetitions.count) runs passed)" : ""
                    return "\(mark) \(suite.identifier)/\(test.name)\(reps)"
                }
            }
            .joined(separator: "\n")
    }

    private func row(_ test: TestCaseResult, suite: SuiteResult) -> some View {
        let id = suite.onlyTestingIdentifier(of: test)   // as Failures names it: never by display name
        let canOpen = project.isLastRunFailure(id)
        return HStack(spacing: DS.Space.s) {
            Image(systemName: icon(test.outcome))
                .foregroundStyle(color(test.outcome))
            Text(test.name).lineLimit(1)
            if test.repetitions.count > 1 {
                Chip(text: "\(test.passedRepetitions) of \(test.repetitions.count) runs passed",
                     color: test.failedRepetitions > 0 && test.passedRepetitions > 0 ? DS.Status.flaky : DS.Status.neutral)
            }
            Spacer()
            if let duration = test.duration {
                Text(Self.duration(duration))
                    .font(DS.Font.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // Every row keeps the button's slot, so durations line up whether a row has it or not.
            Button { project.showFailure(id) } label: { Image(systemName: "arrow.forward.circle") }
                .buttonStyle(.borderless)
                .help("Compare with the run’s other failures")
                .opacity(canOpen ? 1 : 0)
                .disabled(!canOpen)
        }
        .listRowSeparator(.hidden)
        // One stop per test; the button becomes the row's action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(test))
        .accessibilityActions {
            if canOpen { Button("Show Failure") { project.showFailure(id) } }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if canOpen { project.showFailure(id) } }
    }

    /// An outcome in words, for VoiceOver ("expectedFailure" is no word).
    nonisolated static func spoken(_ outcome: TestOutcome) -> String {
        switch outcome {
        case .passed: "Passed"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .expectedFailure: "Expected failure"
        case .unknown: "Unknown result"
        }
    }

    /// A test's row in words: "payButton(), Failed, 2 of 5 runs passed, 0.4s".
    nonisolated static func spoken(_ test: TestCaseResult) -> String {
        var parts = [test.name, spoken(test.outcome)]
        if test.repetitions.count > 1 { parts.append("\(test.passedRepetitions) of \(test.repetitions.count) runs passed") }
        if let duration = test.duration { parts.append(Self.duration(duration)) }
        return parts.joined(separator: ", ")
    }

    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 1))
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
