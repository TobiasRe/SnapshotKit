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

    /// What the row is called, for VoiceOver as the highlight moves.
    var title: String {
        switch self {
        case .project(let project): project.name
        case .command(let command): command.title
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
            } else if let s = FuzzyMatcher.pathScore(query, in: project.path) {
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
        if idle && project.hasRemote {
            commands.append(.init(title: "Run on Remote Machine", symbol: "network", shortcut: "⌃⌘R") { project.runRemote() })
        }
        if project.canReRecordSelection {
            commands.append(.init(title: project.reRecordSelectionTitle, symbol: "camera", shortcut: "⇧⌘R") { project.reRecordSelection() })
        }
        if let file = project.testToOpen {
            commands.append(.init(title: "Open Test in Xcode", symbol: "hammer", shortcut: "⌥⌘O") { project.openTestInXcode(file) })
        }
        if idle && project.environment != nil && !project.failingSuites.isEmpty {
            commands.append(.init(title: "Re-record Failing Suites", symbol: "camera.badge.ellipsis", shortcut: "⌥⇧⌘R") { project.reRecordFailed() })
            commands.append(.init(title: "Check Flakiness of Failing Tests", symbol: "waveform.path.ecg", shortcut: "⌥⌘R") { project.checkFlakiness() })
        }
        if idle && project.environment != nil && !project.recordableSnapshots.isEmpty {
            commands.append(.init(title: "Re-record All Snapshot Tests…", symbol: "camera.on.rectangle", shortcut: nil) {
                project.confirmReRecordAll = true
            })
        }
        if project.isRunning {
            commands.append(.init(title: "Cancel Run", symbol: "stop", shortcut: "⌘.") { project.cancel() })
        }
        // The sidebar's sections, by their full names: "Show Changes vs develop".
        for (index, section) in project.menuSections.enumerated() where project.isListed(section) {
            commands.append(.init(title: "Show " + project.title(of: section), symbol: SectionList.symbol(of: section),
                                  shortcut: "⌥⌘\(index + 1)") { project.section = section })
        }
        commands.append(.init(title: "Refresh Changes", symbol: "arrow.clockwise", shortcut: nil) { project.refreshChanges() })
        if project.displayedChanges.contains(where: { !project.viewedChanges.contains($0.id) }) {
            let title = project.changesAreFiltered ? "Mark All Shown Changes as Viewed" : "Mark All Changes as Viewed"
            commands.append(.init(title: title, symbol: "checkmark.circle", shortcut: nil) {
                if project.section.content != .changes { project.section = .comparison }
                project.setAllViewed(true)
            })
        }
        if idle {
            commands.append(.init(title: "Import Result Bundle…", symbol: "square.and.arrow.down", shortcut: "⇧⌘O") { app.importResultBundleFromPanel() })
            commands.append(.init(title: "Load Failed CI Job…", symbol: "arrow.down.circle", shortcut: "⇧⌘L") { app.loadCIJobFromPrompt() })
        }
        // The sidebar's context menu, for the keyboard.
        let current = project.project
        commands += [
            .init(title: app.isPinned(current) ? "Unpin Project" : "Pin Project", symbol: "pin", shortcut: nil) { app.togglePin(current) },
            .init(title: "Reveal Project in Finder", symbol: "folder", shortcut: nil) {
                NSWorkspace.shared.activateFileViewerSelecting([current.url])
            },
            .init(title: "Remove Project from List", symbol: "minus.circle", shortcut: nil) { app.remove(current) },
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
                .font(DS.Font.monogramSymbol)
                .monogramTile()
            Text(command.title).lineLimit(1)
            Spacer(minLength: DS.Space.m)
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(DS.Font.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
