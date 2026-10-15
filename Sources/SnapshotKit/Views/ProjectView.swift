import SnapshotKitCore
import SwiftUI

struct ProjectView: View {
    @ObservedObject var project: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            if let message = project.lastMessage, !project.isRunning {
                NoticeBanner(text: message, isError: project.lastMessageIsError)
                    .padding([.horizontal, .top], 12)
            }
            switch project.tab {
            case .run: RunTab(project: project)
            case .failures: FailuresTab(project: project)
            case .changes: ChangesTab(project: project)
            }
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
            ToolbarItemGroup(placement: .primaryAction) {
                if project.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel", systemImage: "stop.fill") { project.cancel() }
                        .help("Cancel (⌘.)")
                } else {
                    Button("Run", systemImage: "play.fill") { project.runTests() }
                        .help("Run snapshot tests with the CI configuration (⌘R)")
                    Button("Re-record Failed", systemImage: "camera.badge.ellipsis") { project.reRecordFailed() }
                        .disabled(project.failingSuites.isEmpty)
                        .help("Re-record only the failing suites (⇧⌘R)")
                }
            }
        }
    }

    private func label(for tab: ProjectTab) -> String {
        switch tab {
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EnvironmentCard(project: project)
                    ActionsCard(project: project)
                    ConfigurationCard(project: project)
                }
                .padding(14)
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)

            VStack(spacing: 0) {
                RunStatusHeader(project: project)
                Divider()
                LogView(project: project)
            }
            .frame(minWidth: 420)
        }
    }
}

struct Card<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct EnvironmentCard: View {
    @ObservedObject var project: ProjectModel

    var body: some View {
        Card(title: "Environment") {
            if let error = project.configError {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            } else if let env = project.environment {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Xcode \(env.xcode.version)" + (env.xcode.build.map { " (\($0))" } ?? ""))
                        Text(env.xcodeIsDefault ? "Not pinned by CI — using the selected Xcode" : env.xcode.path)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "hammer.fill").foregroundStyle(.green) }
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(env.simulator.name) · \(env.simulator.platform) \(env.simulator.osVersion)")
                        Text(env.simulator.state).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "iphone").foregroundStyle(.green) }
            } else if let error = project.environmentError {
                Label {
                    Text(error).font(.callout).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Button("Check Again") { project.validateEnvironment() }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Checking Xcode and simulator…").foregroundStyle(.secondary) }
            }
        }
    }
}

struct ActionsCard: View {
    @ObservedObject var project: ProjectModel

    var body: some View {
        Card(title: "Actions") {
            Picker("Scope", selection: Binding(
                get: { project.settings.module ?? "" },
                set: { value in project.updateSettings { $0.module = value.isEmpty ? nil : value } }
            )) {
                Text("What CI runs").tag("")
                if !project.modules.isEmpty { Divider() }
                ForEach(project.modules, id: \.self) { Text($0).tag($0) }
            }
            .disabled(project.isRunning)

            VStack(alignment: .leading, spacing: 6) {
                Button { project.runTests() } label: { Label("Run Snapshot Tests", systemImage: "play.fill").frame(maxWidth: .infinity, alignment: .leading) }
                    .keyboardShortcut("r")
                    .disabled(project.isRunning || project.environment == nil)
                Button { project.reRecordFailed() } label: {
                    Label("Re-record \(project.failingSuites.count) Failed Suite\(project.failingSuites.count == 1 ? "" : "s")", systemImage: "camera.badge.ellipsis")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(project.isRunning || project.failingSuites.isEmpty || project.environment == nil)
                Button { project.checkFlakiness() } label: {
                    Label("Check Flakiness (\(project.store.settings.flakeIterations)×)", systemImage: "dice")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(project.isRunning || project.failingSuites.isEmpty || project.environment == nil)
            }
            .controlSize(.large)

            Divider()
            HStack {
                Image(systemName: "server.rack")
                Text(project.config?.remoteHost.map { "Remote: \($0)" } ?? "No remote machine")
                    .foregroundStyle(project.hasRemote ? .primary : .secondary)
            }
            .font(.callout)
            HStack {
                Button("Run on Remote") { project.runRemote() }
                Menu("More") {
                    Button("Re-record Failed on Remote") { project.reRecordOnRemote() }
                        .disabled(project.failingSuites.isEmpty)
                    Button("Check Flakiness on Remote") { project.checkFlakiness(remote: true) }
                        .disabled(project.failingSuites.isEmpty)
                }
                .fixedSize()
            }
            .disabled(project.isRunning || !project.hasRemote)
            Text("Syncs the working tree to the CI machine over SSH and runs the same command there.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ConfigurationCard: View {
    @ObservedObject var project: ProjectModel
    @State private var baseBranch = ""
    @State private var remoteHost = ""

    var body: some View {
        Card(title: "Configuration") {
            if let ctx = project.context {
                let c = project.config ?? ctx.config
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                    row("Scheme", c.scheme, c.source(of: .scheme))
                    if let ws = c.workspace { row("Workspace", ws, c.source(of: .workspace)) }
                    if let p = c.project { row("Project", p, c.source(of: .project)) }
                    row("Test plan", c.testPlan, c.source(of: .testPlan))
                    row("Only testing", c.onlyTesting.isEmpty ? nil : c.onlyTesting.joined(separator: ", "), c.source(of: .onlyTesting))
                    row("Xcode", c.xcodeVersion ?? c.developerDir, c.source(of: .xcodeVersion) ?? c.source(of: .developerDir))
                    row("Device", c.deviceName.map { "\($0)" + (c.osVersion.map { " (\($0))" } ?? "") }, c.source(of: .deviceName))
                    if let wd = c.workingDirectory { row("Directory", wd, c.source(of: .workingDirectory)) }
                }
                Text(ctx.resolved.ciFiles.isEmpty ? "No CI files found" : "Read from " + ctx.resolved.ciFiles.joined(separator: ", ")
                     + (ctx.resolved.overrideFile.map { " + \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ctx.resolved.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }

                Divider()
                LabeledContent("Base branch") {
                    TextField(project.detectedBaseBranch ?? "develop", text: $baseBranch)
                        .onSubmit { project.updateSettings { $0.baseBranch = baseBranch.isEmpty ? nil : baseBranch } }
                }
                Text(project.detectedBaseBranch.map { "Detected: \($0) (\(ctx.config.source(of: .baseBranch) ?? "auto"))" } ?? "Not detected")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Remote host") {
                    TextField(ctx.resolved.config.remoteHost ?? "user@ci-mac", text: $remoteHost)
                        .onSubmit { project.updateSettings { $0.remoteHost = remoteHost.isEmpty ? nil : remoteHost } }
                }
            }
        }
        .onAppear {
            baseBranch = project.settings.baseBranch ?? ""
            remoteHost = project.settings.remoteHost ?? ""
        }
    }

    @ViewBuilder
    private func row(_ name: String, _ value: String?, _ source: String?) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(value ?? "—").textSelection(.enabled)
                if let source, value != nil {
                    Text(source).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct RunStatusHeader: View {
    @ObservedObject var project: ProjectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.isRunning ? project.stageLabel : (project.lastResult == nil ? "Ready" : "Last run"))
                    .font(.title3.weight(.semibold))
                if project.isRunning {
                    Text(project.phase.label).foregroundStyle(.secondary)
                }
                Spacer()
                CountBadge(value: project.passed, label: "passed", color: .green)
                CountBadge(value: project.failed, label: "failed", color: .red)
                CountBadge(value: project.skipped, label: "skipped", color: .secondary)
            }
            if project.isRunning {
                if let total = project.expectedTotal, total > 0, project.phase == .testing {
                    ProgressView(value: Double(min(project.passed + project.failed + project.skipped, total)), total: Double(total))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if let test = project.currentTest {
                    Text("Running \(test)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if let result = project.lastResult {
                Text(result.commandLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
    }
}

struct CountBadge: View {
    var value: Int
    var label: String
    var color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)").font(.body.monospacedDigit().weight(.semibold))
            Text(label).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(value > 0 ? 0.15 : 0.05)))
    }
}

struct LogView: View {
    @ObservedObject var project: ProjectModel

    var body: some View {
        let lines = project.visibleLog
        VStack(spacing: 0) {
            HStack {
                Text(project.showFullLog ? "Full output" : "Test output").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Show build output", isOn: $project.showFullLog)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                        if lines.isEmpty {
                            Text(project.isRunning ? "Waiting for output…" : "Output from the next run appears here.")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: lines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottomLeading) }
                }
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
