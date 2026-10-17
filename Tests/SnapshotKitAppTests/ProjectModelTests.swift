import AppKit
import Foundation
import SnapshotKitCore
import SwiftUI
import Testing
@testable import SnapshotKit

extension AppUITests {
    @MainActor
    @Suite(.serialized)
    struct ProjectModelTests {
        /// A repo on `feature` with one committed snapshot change and one uncommitted re-record.
        func makeRepo() throws -> (URL, String) {
            let dir = AppFixtures.home.appendingPathComponent("model-\(UUID().uuidString)").resolvingSymlinksInPath()
            let png = "Tests/AppTests/__Snapshots__/CardTests/card.1.png"
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(png).deletingLastPathComponent(), withIntermediateDirectories: true)
            func git(_ args: String...) throws { try Shell.output(["git"] + args, in: dir) }
            try git("init", "-q", "-b", "develop")
            try git("config", "user.email", "t@example.com")
            try git("config", "user.name", "T")
            try git("config", "commit.gpgsign", "false")
            try AppFixtures.reference.write(to: dir.appendingPathComponent(png))
            try git("add", "-A"); try git("commit", "-qm", "base")
            try git("checkout", "-qb", "feature")
            try AppFixtures.actual.write(to: dir.appendingPathComponent(png))
            return (dir, png)
        }

        /// Waits for the changes to load: up to ten seconds, as git is slow while the rest of the
        /// suite runs in parallel (two and a half seconds was not always enough).
        func waitForChanges(_ model: ProjectModel) async {
            for _ in 0..<200 where model.isLoadingChanges || model.changeSet == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        /// A snapshot recorded outside the app (Xcode, the CLI) appears without a manual refresh.
        @Test func picksUpSnapshotsWrittenElsewhere() async throws {
            let (repo, _) = try makeRepo()
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            await waitForChanges(model)
            for _ in 0..<200 where model.library == nil { try await Task.sleep(for: .milliseconds(50)) }
            #expect(model.library?.files.count == 1)

            let added = "Tests/AppTests/__Snapshots__/CardTests/card.2.png"
            try AppFixtures.actual.write(to: repo.appendingPathComponent(added))
            for _ in 0..<200 where model.library?.files.count != 2 { try await Task.sleep(for: .milliseconds(50)) }
            #expect(model.library?.files.map(\.path).contains(added) == true)
        }

        @Test func discardRestoresUncommittedSnapshot() async throws {
            let (repo, png) = try makeRepo()
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            await waitForChanges(model)
            let change = try #require(model.changeSet?.changes.first)
            #expect(change.kind == .uncommitted)
            #expect(model.canDiscard(change))

            model.discard(change)
            #expect(try Data(contentsOf: repo.appendingPathComponent(png)) == AppFixtures.reference)
            #expect(!model.lastMessageIsError)
        }

        @Test func viewingMovesOnAndIsRemembered() async throws {
            let (repo, png) = try makeRepo()
            let second = png.replacingOccurrences(of: "card.1.png", with: "list.1.png")
            try AppFixtures.badged.write(to: repo.appendingPathComponent(second))
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            await waitForChanges(model)
            let first = try #require(model.filteredChanges.first)
            model.selectedChangeID = first.id
            model.setViewed(true, for: first)
            #expect(model.selectedChangeID == model.filteredChanges.last?.id)

            // A fresh model reads the marks back.
            let reopened = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            reopened.updateSettings { $0.baseBranch = "develop" }
            await waitForChanges(reopened)
            #expect(reopened.viewedChanges == [first.id])
            reopened.hideViewed = true
            #expect(reopened.filteredChanges.map(\.id) == [model.filteredChanges.last!.id])
        }

        @Test func discardsOnlyInvisibleReRecords() async throws {
            let (repo, png) = try makeRepo()
            let noisy = png.replacingOccurrences(of: "card.1.png", with: "noisy.1.png")
            let git = Git(root: repo)
            // Committed on the base branch, then re-recorded with noise on the feature branch.
            try git.run(["checkout", "-q", "develop"])
            try AppFixtures.reference.write(to: repo.appendingPathComponent(noisy))
            try git.run(["add", "--", noisy]); try git.run(["commit", "-qm", "noisy"])
            try git.run(["checkout", "-q", "feature"]); try git.run(["merge", "-q", "--ff-only", "develop"])
            try AppFixtures.renderingNoise.write(to: repo.appendingPathComponent(noisy))
            // card.1.png has a visible uncommitted change and must survive.
            try AppFixtures.actual.write(to: repo.appendingPathComponent(png))

            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            await waitForChanges(model)
            for _ in 0..<500 where model.invisibleUncommitted.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.invisibleUncommitted.map(\.fileName) == ["noisy.1.png"])

            model.discardInvisibleChanges()
            for _ in 0..<500 where model.lastMessage == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(try Data(contentsOf: repo.appendingPathComponent(noisy)) == AppFixtures.reference)
            #expect(try Data(contentsOf: repo.appendingPathComponent(png)) == AppFixtures.actual)
            #expect(model.lastMessage?.hasPrefix("Discarded 1 re-recorded snapshot") == true)
        }

        @Test func navigationFollowsTheListOrder() {
            let store = AppFixtures.store()
            let model = AppFixtures.project(.changes, store: store)
            #expect(model.displayedChanges.map(\.testName) == ["payButton", "summary", "badge", "legacyHeader"])
            model.selectedChangeID = model.displayedChanges[0].id
            model.selectAdjacent(1)
            #expect(model.selectedChange?.testName == "summary")
            // legacyHeader is already viewed, so marking summary skips ahead to badge.
            model.setViewed(true, for: model.selectedChange!)
            #expect(model.selectedChange?.testName == "badge")
            model.selectAdjacent(5)
            #expect(model.selectedChange?.testName == "legacyHeader")

            model.tab = .failures
            model.selectedFailureID = nil
            model.selectAdjacent(1)
            #expect(model.selectedFailureID == model.displayedFailures.first?.id)
        }

        @Test func variantComparisonFollowsTheTestNotOtherSelections() {
            let model = AppFixtures.project(.library, store: AppFixtures.store())
            let dark = model.displayedSnapshots[0], light = model.displayedSnapshots[1]
            #expect(model.variants(of: dark).map(\.variant) == ["dark", "light"])
            model.selectedSnapshotID = dark.id
            model.comparison = .variant(light)
            model.selectedSnapshotID = light.id      // stepping through the same test's variants
            #expect(model.comparison == .variant(light))
            model.selectedSnapshotID = model.displayedSnapshots[2].id   // another test
            #expect(model.comparison == nil)
            model.comparison = .version(AppFixtures.snapshotVersions[0])
            model.selectedSnapshotID = dark.id
            #expect(model.comparison == nil)
        }

        @Test func reRecordSelectionFollowsTheTab() {
            let model = AppFixtures.project(.library, store: AppFixtures.store())
            model.tab = .snapshots
            model.selectedSnapshotID = model.displayedSnapshots.first?.id
            #expect(model.canReRecordSelection)
            model.selectedSnapshotID = AppFixtures.libraryImages.first { $0.0.testName == "oldAvatar" }?.0.id
            #expect(!model.canReRecordSelection)   // orphaned: its test is gone
            model.tab = .changes
            model.selectedChangeID = AppFixtures.changes.first { $0.0.kind == .deleted }?.0.id
            #expect(!model.canReRecordSelection)   // nothing to record for a deleted snapshot
            model.selectedChangeID = AppFixtures.changes[0].0.id
            #expect(model.canReRecordSelection)
            model.tab = .run
            #expect(!model.canReRecordSelection)
        }

        @Test func listOrderFollowsFilterScopeAndSort() {
            // The order is cached between redraws; every input has to invalidate it.
            let model = AppFixtures.project(.library, store: AppFixtures.store())
            let all = model.displayedSnapshots
            #expect(all.count == AppFixtures.libraryImages.count)
            model.libraryFilter = "payButton"
            #expect(model.displayedSnapshots.allSatisfy { $0.testName == "payButton" })
            #expect(model.displayedTree.flatMap(\.suites).map(\.name) == ["CheckoutViewTests"])
            model.libraryFilter = ""
            model.libraryScope = .failing
            #expect(model.displayedSnapshots.map(\.testName) == ["badge"])
            model.libraryScope = .all
            model.librarySort = .size
            #expect(model.displayedSnapshots.map(\.byteSize) == all.map(\.byteSize).sorted(by: >))
            model.librarySort = .name
            #expect(model.displayedSnapshots == all)
        }

        /// Scanning a folder finds its projects and says so; nothing found is never silent.
        @Test func scanningAFolderFindsProjectsAndSaysSo() async throws {
            let root = AppFixtures.home.appendingPathComponent("scan-\(UUID().uuidString)").resolvingSymlinksInPath()
            let repo = root.appendingPathComponent("team/app")
            let snapshots = repo.appendingPathComponent("Tests/__Snapshots__/S")
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            try Shell.output(["git", "init", "-q"], in: repo)
            try Data([1]).write(to: snapshots.appendingPathComponent("a.1.png"))   // recorded, not committed

            let app = AppModel(store: AppFixtures.store())
            app.addDroppedFolders([root])                       // a plain folder becomes a scan folder
            for _ in 0..<200 where app.startupNotice == nil { try await Task.sleep(for: .milliseconds(50)) }
            #expect(app.store.settings.scanRoots == [root.path])
            #expect(app.projects.contains { $0.path == repo.path })
            #expect(app.startupNotice?.hasPrefix("Found 1 project with snapshot tests in") == true)
        }

        @Test func scanSummaryExplainsAnEmptyOrUnreadableFolder() {
            let url = URL(fileURLWithPath: "/work")
            let none = AppModel.scanSummary([ProjectScanner.Report(root: url, projects: [], readable: true)])
            #expect(none?.hasPrefix("No git repositories with snapshot tests in /work") == true)
            let blocked = AppModel.scanSummary([ProjectScanner.Report(root: url, projects: [], readable: false)])
            #expect(blocked?.contains("Privacy & Security") == true)
            #expect(AppModel.scanSummary([]) == nil)
        }

        @Test func logMatchesAreMarked() {
            func marked(_ line: String, _ terms: [String]) -> [String] {
                let text = LogView.highlighted(line, terms: terms)
                return text.runs.filter { $0.backgroundColor != nil }.map { String(text[$0.range].characters) }
            }
            #expect(marked("✘ Test payButton() failed", ["paybutton"]) == ["payButton"])
            #expect(marked("a b a", ["a"]) == ["a", "a"])
            #expect(marked("nothing here", []).isEmpty)
            #expect(marked("İstanbul paybutton", ["pay"]) == ["pay"])   // "İ" lowercases to one character too
        }

        @Test func marksEveryShownChangeViewedAndBack() {
            let model = AppFixtures.project(.changes, store: AppFixtures.store())
            model.setAllViewed(true)
            #expect(model.displayedChanges.allSatisfy { model.viewedChanges.contains($0.id) })
            model.setAllViewed(false)
            #expect(model.viewedChanges.isEmpty)
        }

        @Test func countersShowOnlyWhenATestHasSeveralSnapshots() {
            let model = AppFixtures.project(.library, store: AppFixtures.store())
            let files = model.library?.files ?? []
            let named = files.first { $0.variant == "dark" }!
            let lone = files.first { $0.testName == "summary" }!
            #expect(model.showsVariant(named))
            #expect(lone.variant == "1" && !model.showsVariant(lone))
            #expect(!model.showsVariant(SnapshotFile(path: "T/__Snapshots__/S/plain.png", byteSize: 0)))
        }

        @Test func paletteRanksProjectsAndCommandsTogether() {
            let projects = [Project(path: "/work/payments-ui"), Project(path: "/work/design-system")]
            let commands = [PaletteCommand(title: "Run Snapshot Tests", symbol: "play", shortcut: "⌘R") {},
                            PaletteCommand(title: "Show Changes", symbol: "arrow.triangle.branch", shortcut: nil) {}]
            let ids = { (query: String) in PaletteItem.ranked(projects: projects, commands: commands, query: query).map(\.id) }
            // Nothing typed: projects first, then commands, in their own order.
            #expect(ids("") == ["project:/work/payments-ui", "project:/work/design-system",
                                "command:Run Snapshot Tests", "command:Show Changes"])
            #expect(ids("run") == ["command:Run Snapshot Tests"])
            #expect(ids("changes") == ["command:Show Changes"])
            #expect(ids("pay") == ["project:/work/payments-ui"])
            #expect(ids("work").allSatisfy { $0.hasPrefix("project:") })   // path matches still find projects
        }

        @Test func paletteOffersOnlyWhatCanBeDoneNow() {
            let app = AppModel(store: AppFixtures.store())
            #expect(PaletteCommand.available(app: app).map(\.title) == ["Add Project…"])   // no project open
            let model = AppFixtures.project(.failedRun, store: app.store)
            app.show(model)
            let titles = PaletteCommand.available(app: app).map(\.title)
            #expect(titles.contains("Re-record Failing Tests"))
            #expect(!titles.contains("Cancel Run"))
        }

        @Test func reRecordAllCoversEveryTestButOrphans() {
            let app = AppModel(store: AppFixtures.store())
            let model = AppFixtures.project(.library, store: app.store)
            app.show(model)
            let files = model.recordableSnapshots
            #expect(files.count == model.library!.files.count - 1)            // oldAvatar's test is gone
            #expect(!files.contains { model.orphanIDs.contains($0.id) })
            #expect(ProjectModel.testCount(files) == 5)                       // payButton's two variants are one test
            #expect(PaletteCommand.available(app: app).map(\.title).contains("Re-record All Snapshot Tests…"))
        }

        @Test func reRecordAllWithNothingRecordedSaysSo() {
            let model = AppFixtures.project(.empty, store: AppFixtures.store())
            #expect(model.recordableSnapshots.isEmpty)
            model.reRecordAll()
            #expect(model.lastMessageIsError)
            #expect(model.lastMessage?.hasPrefix("No snapshot tests to re-record") == true)
            #expect(!model.isRunning)
        }

        @Test func listWidthStaysWithinItsBoundsAndLeavesTheDetailRoom() {
            typealias Split = ListDetailSplit<SwiftUI.EmptyView, SwiftUI.EmptyView>
            #expect(Split.clamp(400, min: 280, available: 1100) == 400)
            #expect(Split.clamp(100, min: 280, available: 1100) == 280)     // never narrower than its minimum
            #expect(Split.clamp(900, min: 280, available: 1400) == 520)     // never wider than its maximum
            #expect(Split.clamp(500, min: 280, available: 800) == 360)      // the detail keeps 440 points
            #expect(Split.clamp(500, min: 300, available: 600) == 300)      // a tiny window: the list's minimum wins
        }

        @Test func showInLibraryClearsFiltersThatHideTheSnapshot() {
            let model = AppFixtures.project(.library, store: AppFixtures.store())
            let header = AppFixtures.libraryImages.first { $0.0.testName == "header" }!.0
            model.libraryScope = .failing
            model.libraryFilter = "payButton"
            model.tab = .changes
            model.showInLibrary(path: header.path)
            #expect(model.tab == .snapshots)
            #expect(model.selectedSnapshotID == header.id)
            #expect(model.displayedSnapshots.contains(header))
            model.showInLibrary(path: "not/a/snapshot.png")
            #expect(model.selectedSnapshotID == header.id)
        }

        @Test func committedChangesCannotBeDiscarded() async throws {
            let (repo, _) = try makeRepo()
            try Shell.output(["git", "commit", "-qam", "re-record"], in: repo)
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            await waitForChanges(model)
            let change = try #require(model.changeSet?.changes.first)
            #expect(change.kind == .committed)
            #expect(!model.canDiscard(change))
        }

        @Test func droppingASubfolderAddsTheRepositoryRoot() throws {
            let (repo, png) = try makeRepo()
            let app = AppModel(store: AppFixtures.store())
            let subfolder = repo.appendingPathComponent(png).deletingLastPathComponent()
            #expect(app.addDroppedFolders([subfolder]))
            #expect(app.current?.project.path == Project(path: repo.path).path)
            #expect(app.projects.contains { $0.path == Project(path: repo.path).path })
            // A file outside any repository is neither a project nor a scan folder.
            let file = AppFixtures.home.appendingPathComponent("loose-\(UUID().uuidString).txt")
            try Data("x".utf8).write(to: file)
            #expect(!app.addDroppedFolders([file]))
        }

        @Test func exportsBaseImageForOpeningElsewhere() async throws {
            let (repo, _) = try makeRepo()
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            await waitForChanges(model)
            let change = try #require(model.changeSet?.changes.first)
            let url = try #require(model.exportBaseImage(for: change))
            #expect(try Data(contentsOf: url) == AppFixtures.reference)
        }

        @Test func incrementalLogMatchesFullFilter() {
            let model = ProjectModel(project: Project(path: "/work/x"), store: AppFixtures.store(), autoload: false)
            var lines: [String] = []
            for i in 0..<9_700 {
                lines.append(i % 3 == 0 ? "✔ Test t\(i)() passed after 0.1 seconds." : "CompileSwift normal arm64 File\(i).swift")
            }
            for batch in stride(from: 0, to: lines.count, by: 97) {
                model.appendLog(Array(lines[batch..<min(batch + 97, lines.count)]))
            }
            let expected = model.log.filter(ProjectModel.isInteresting)
            #expect(model.visibleLog == expected)
            #expect(model.log.count <= ProjectModel.maxLogLines + 1000)

            model.logFilter = "t42"
            #expect(model.visibleLog == expected.filter { $0.contains("t42") })
            model.showFullLog = true
            model.appendLog(["CompileSwift t42.swift"])
            #expect(model.visibleLog.last == "CompileSwift t42.swift")
        }

        @Test func reloadIsAsynchronousAndLoadsConfiguration() async throws {
            let (repo, _) = try makeRepo()
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            for _ in 0..<500 where model.context == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.context?.repository.path == repo.path)
            #expect(model.currentBranch == "feature")
            #expect(model.branches.prefix(1) == ["develop"])
        }
    }
}
