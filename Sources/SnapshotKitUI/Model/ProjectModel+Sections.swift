import AppKit
import Foundation
import Observation
import SnapshotKitCore

/// The sidebar's sections as the project names and counts them: read-only, from what the model holds.
extension ProjectModel {
    /// What a section's badge counts: changes, failing tests or snapshots; nil before it is known.
    func count(of section: ProjectSection) -> Int? {
        switch section {
        case .workingCopy: changeSet.map { $0.changes.filter(\.isUncommitted).count }
        case .comparison: changeSet?.changes.count
        case .lastRun: failureSets[.lastRun]?.items.count ?? 0
        case .ciJob(let job): failureSets[.ciJob(job)]?.items.count
        case .run: nil
        case .library: library?.files.count
        case .orphaned: orphanIDs.count
        }
    }

    /// The sections with a menu shortcut (⌥⌘1…), in sidebar order. CI jobs come and go; ⌘K finds them.
    var menuSections: [ProjectSection] { [.workingCopy, .comparison, .lastRun, .run, .library, .orphaned] }

    /// Whether the sidebar lists `section`: Orphaned only while there are orphans (or it is open), a CI
    /// job while it is offered or loaded.
    func isListed(_ section: ProjectSection) -> Bool {
        switch section {
        case .orphaned: !orphanIDs.isEmpty || self.section == .orphaned
        case .ciJob(let id): ciJob(id) != nil
        default: true
        }
    }

    /// A section's name in the window title and for VoiceOver.
    func title(of section: ProjectSection) -> String {
        switch section {
        case .workingCopy: "Working Copy"
        case .comparison: baseBranch.map { "Changes vs \($0)" } ?? "Changes vs Base Branch"
        case .lastRun: "Last Run"
        case .ciJob(let id): "CI Job " + (ciJob(id).map { "\($0.name) #\(id)" } ?? "#\(id)")
        case .run: "Run"
        case .library: "All Snapshots"
        case .orphaned: "Orphaned Snapshots"
        }
    }

    /// A section's name in the sidebar, where its group heading says the rest: "vs develop" under
    /// Workspace, the job's name under its merge request.
    func shortTitle(of section: ProjectSection) -> String {
        switch section {
        case .comparison: "vs \(baseBranch ?? "base branch")"
        case .ciJob(let id): ciJob(id).map { "\($0.name) #\(id)" } ?? "#\(id)"
        case .orphaned: "Orphaned"
        default: title(of: section)
        }
    }

    /// A section's count in words, as VoiceOver reads it beside the name.
    func countLabel(of section: ProjectSection) -> String? {
        if case .ciJob(let id) = section, failureSets[.ciJob(id)] == nil {
            return loadingCIJobs.contains(id) ? "loading" : "failed, not loaded"
        }
        if section == .run { return isRunning ? stageLabel : nil }
        guard let count = count(of: section) else { return nil }
        let noun = switch section {
        case .workingCopy: "uncommitted change"
        case .comparison: "change"
        case .lastRun, .ciJob: "failing test"
        case .run: ""
        case .library, .orphaned: "snapshot"
        }
        return "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// The branch checked out, or "detached HEAD"; nil until the project has loaded.
    var branchLabel: String? {
        currentBranch ?? (context == nil && configError == nil ? nil : "detached HEAD")
    }
}
