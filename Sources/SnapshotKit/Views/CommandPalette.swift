import SnapshotKitCore
import SwiftUI

/// An action the ⌘K palette offers next to projects, with the shortcut that does the same.
struct PaletteCommand: Identifiable {
    var id: String { title }
    var title: String
    var symbol: String
    var shortcut: String?
    var run: () -> Void
}

/// One result in the palette: a project to open or a command to run.
enum PaletteItem: Identifiable {
    case project(Project)
    case command(PaletteCommand)

    var id: String {
        switch self {
        case .project(let project): "project:" + project.path
        case .command(let command): "command:" + command.id
        }
    }

    /// Projects first when nothing is typed; otherwise the best match first, a name or title
    /// match always ahead of a path match.
    @MainActor
    static func ranked(projects: [Project], commands: [PaletteCommand], query: String) -> [PaletteItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return projects.map(PaletteItem.project) + commands.map(PaletteItem.command)
        }
        var scored: [(item: PaletteItem, score: Int, order: Int)] = []
        for (i, project) in projects.enumerated() {
            if let s = FuzzyMatcher.score(query, in: project.name) {
                scored.append((.project(project), s + 1000, i))
            } else if let s = FuzzyMatcher.score(query, in: project.path) {
                scored.append((.project(project), s, i))
            }
        }
        for (i, command) in commands.enumerated() {
            if let s = FuzzyMatcher.score(query, in: command.title) {
                scored.append((.command(command), s + 1000, projects.count + i))
            }
        }
        return scored.sorted { ($0.score, -$0.order) > ($1.score, -$1.order) }.map(\.item)
    }
}

extension PaletteCommand {
    /// What can be done right now in the open project; unavailable commands are left out.
    @MainActor
    static func available(app: AppModel) -> [PaletteCommand] {
        guard let project = app.current else {
            return [PaletteCommand(title: "Add Project…", symbol: "plus", shortcut: "⌘O") { app.addProjectFromPanel() }]
        }
        var commands: [PaletteCommand] = []
        let idle = !project.isRunning
        if idle && project.environment != nil {
            commands.append(.init(title: "Run Snapshot Tests", symbol: "play", shortcut: "⌘R") { project.runTests() })
        }
        if project.canReRecordSelection {
            commands.append(.init(title: "Re-record Selected Test", symbol: "camera", shortcut: "⇧⌘R") { project.reRecordSelection() })
        }
        if idle && !project.failingSuites.isEmpty {
            commands.append(.init(title: "Re-record Failing Tests", symbol: "camera.badge.ellipsis", shortcut: "⌥⇧⌘R") { project.reRecordFailed() })
            commands.append(.init(title: "Check Flakiness of Failed Tests", symbol: "waveform.path.ecg", shortcut: "⌥⌘R") { project.checkFlakiness() })
        }
        if project.isRunning {
            commands.append(.init(title: "Cancel Run", symbol: "stop", shortcut: "⌘.") { project.cancel() })
        }
        commands += [
            .init(title: "Show Snapshots", symbol: "photo.stack", shortcut: "⌥⌘1") { project.tab = .snapshots },
            .init(title: "Show Changes", symbol: "arrow.triangle.branch", shortcut: "⌥⌘2") { project.tab = .changes },
            .init(title: "Show Failures", symbol: "xmark.octagon", shortcut: "⌥⌘3") { project.tab = .failures },
            .init(title: "Show Run", symbol: "terminal", shortcut: "⌥⌘4") { project.tab = .run },
            .init(title: "Import Result Bundle…", symbol: "square.and.arrow.down", shortcut: "⇧⌘O") { app.importResultBundleFromPanel() },
            .init(title: "Refresh Changes", symbol: "arrow.clockwise", shortcut: nil) { project.refreshChanges() },
            .init(title: "Mark All Changes as Viewed", symbol: "checkmark.circle", shortcut: nil) {
                project.tab = .changes
                project.setAllViewed(true)
            },
            .init(title: "Add Project…", symbol: "plus", shortcut: "⌘O") { app.addProjectFromPanel() },
        ]
        return commands
    }
}

/// A command's row in the palette: icon, title, and its shortcut where a project row shows its folder.
struct PaletteCommandRow: View {
    var command: PaletteCommand
    var highlighted: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: command.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.7))
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(DS.Surface.hairline))
                .accessibilityHidden(true)
            Text(command.title).lineLimit(1)
            Spacer(minLength: DS.Space.m)
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(DS.Font.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .frame(height: QuickSwitcherView.rowHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(highlighted ? DS.Surface.selection : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}
