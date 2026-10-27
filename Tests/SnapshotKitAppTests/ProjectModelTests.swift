import AppKit
import Foundation
import SnapshotKitCore
import SwiftUI
import Testing
@testable import SnapshotKitUI

extension AppUITests {
    @MainActor
    @Suite(.serialized)
    struct ProjectModelTests {
        init() {
            // Also isolates the process (see `AppFixtures.home`): no git configuration of this machine's user.
            AppFixtures.resetDefaults()
        }

        /// A repo on `feature` with one committed snapshot change and one uncommitted re-record.
        func makeRepo() throws -> (URL, String) {
            let dir = AppFixtures.temporaryDirectory("model")
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

        /// Waits until `condition` holds, and fails the test if it doesn't within ten seconds: git and
        /// the fake Xcodes are slow while other test processes run (two and a half seconds was not
        /// always enough).
        func waitUntil(_ condition: @autoclosure () -> Bool, _ comment: Comment,
                       sourceLocation: SourceLocation = #_sourceLocation) async throws {
            for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
            try #require(condition(), comment, sourceLocation: sourceLocation)
        }

        /// Waits for the changes to load.
        func waitForChanges(_ model: ProjectModel, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            try await waitUntil(!model.isLoadingChanges && model.changeSet != nil, "the changes didn't load",
                                sourceLocation: sourceLocation)
        }

        /// A snapshot recorded outside the app (Xcode, the CLI) appears without a manual refresh.
        @Test func picksUpSnapshotsWrittenElsewhere() async throws {
            let (repo, _) = try makeRepo()
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            try await waitForChanges(model)
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
            try await waitForChanges(model)
            let change = try #require(model.changeSet?.changes.first)
            #expect(change.kind == .uncommitted)
            #expect(model.canDiscard(change))

            model.discard(change)
            #expect(try Data(contentsOf: repo.appendingPathComponent(png)) == AppFixtures.reference)
            #expect(!model.lastMessageIsError)
        }

        /// A snapshot deleted on this branch and recorded again is an uncommitted change with no
        /// version in HEAD to restore: discarding removes it, staged or not.
        @Test func discardRemovesASnapshotRecordedAgainAfterItsDeletion() async throws {
            for staged in [false, true] {
                let (repo, png) = try makeRepo()
                try Shell.output(["git", "rm", "-qf", "--", png], in: repo)
                try Shell.output(["git", "commit", "-qm", "delete"], in: repo)
                let file = repo.appendingPathComponent(png)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try AppFixtures.actual.write(to: file)
                if staged { try Shell.output(["git", "add", "--", png], in: repo) }
                let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
                model.updateSettings { $0.baseBranch = "develop" }
                try await waitForChanges(model)
                let change = try #require(model.changeSet?.changes.first)
                #expect(change.kind == .uncommitted)
                #expect(change.isUntracked == !staged)
                #expect(model.canDiscard(change))

                model.discard(change)
                #expect(model.lastMessage == "Discarded the working-tree change to card.1.png.")
                #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(png).path))
                #expect(try Shell.output(["git", "status", "--porcelain"], in: repo).isEmpty)
            }
        }

        @Test func viewingMovesOnAndIsRemembered() async throws {
            let (repo, png) = try makeRepo()
            let second = png.replacingOccurrences(of: "card.1.png", with: "list.1.png")
            try AppFixtures.badged.write(to: repo.appendingPathComponent(second))
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            try await waitForChanges(model)
            let first = try #require(model.filteredChanges.first)
            model.selectedChangeID = first.id
            model.setViewed(true, for: first)
            let next = try #require(model.filteredChanges.last)
            #expect(model.selectedChangeID == next.id)

            // A fresh model reads the marks back.
            let reopened = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            reopened.updateSettings { $0.baseBranch = "develop" }
            try await waitForChanges(reopened)
            #expect(reopened.viewedChanges == [first.id])
            reopened.hideViewed = true
            #expect(reopened.filteredChanges.map(\.id) == [next.id])
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
            try await waitForChanges(model)
            for _ in 0..<500 where model.invisibleUncommitted.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.invisibleUncommitted.map(\.fileName) == ["noisy.1.png"])

            model.discardInvisibleChanges()
            for _ in 0..<500 where model.lastMessage == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(try Data(contentsOf: repo.appendingPathComponent(noisy)) == AppFixtures.reference)
            #expect(try Data(contentsOf: repo.appendingPathComponent(png)) == AppFixtures.actual)
            #expect(model.lastMessage == "Discarded 1 re-recorded snapshot with no visible change.")
        }

        @Test func navigationFollowsTheListOrder() throws {
            let store = AppFixtures.store()
            let model = AppFixtures.project(.changes, store: store)
            #expect(model.displayedChanges.map(\.testName) == ["payButton", "summary", "badge", "legacyHeader"])
            model.selectedChangeID = model.displayedChanges[0].id
            model.selectAdjacent(1)
            #expect(model.selectedChange?.testName == "summary")
            // legacyHeader is already viewed, so marking summary skips ahead to badge.
            model.setViewed(true, for: try #require(model.selectedChange))
            #expect(model.selectedChange?.testName == "badge")
            model.selectAdjacent(5)
            #expect(model.selectedChange?.testName == "legacyHeader")

            model.section = .lastRun
            #expect(model.displayedFailures.map(\.id) == ["AppSnapshotTests/CheckoutViewTests/payButton()",
                                                          "AppSnapshotTests/ProfileViewTests/badge()"])
            model.selectedFailureID = nil
            model.selectAdjacent(1)                         // nothing selected: the first row
            #expect(model.selectedFailureID == "AppSnapshotTests/CheckoutViewTests/payButton()")
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

        /// Working copy lists what isn't committed, whatever its kind; comparing with the base lists
        /// every change of the kinds chosen. Between the two, the selection moves to a row the other shows.
        @Test func workingCopyListsTheUncommittedChanges() throws {
            let model = AppFixtures.project(.changes, store: AppFixtures.store())
            model.section = .comparison
            #expect(model.displayedChanges.count == 4)
            model.selectedChangeID = try #require(model.displayedChanges.first { $0.testName == "payButton" }).id
            model.changeKinds = [.committed]
            model.section = .workingCopy
            // The kinds menu is the comparison's: Working copy shows the new, untracked badge too.
            #expect(model.displayedChanges.map(\.testName) == ["summary", "badge"])
            #expect(model.selectedChange?.testName == "summary")
            #expect(model.count(of: .workingCopy) == 2)
            #expect(model.count(of: .comparison) == 4)
            #expect(!model.changesAreFiltered)

            // With nothing uncommitted, Working Copy shows no change, also not the one vs develop selected.
            var f = ProjectFixture()
            var committed = AppFixtures.changeSet
            committed.changes.removeAll(where: \.isUncommitted)
            f.changeSet = committed
            f.section = .comparison
            model.apply(f)
            #expect(model.selectedChange != nil)
            model.section = .workingCopy
            #expect(model.displayedChanges.isEmpty && model.shownChange == nil)
        }

        /// A CI job's failures have an item of their own, under the job's merge request, beside the
        /// last run's; the branch's other failed job waits there to be loaded.
        @Test func aCIJobsFailuresHaveTheirOwnItem() {
            let model = AppFixtures.project(.ciJob, store: AppFixtures.store())
            #expect(model.section == .ciJob(4567) && model.failureOrigin == .ciJob(4567))
            #expect(model.ciJobGroups.map(\.title) == ["CI · !12"])
            #expect(model.ciJobGroups.first?.jobs.map(\.id) == [4567, 4568])
            #expect(model.isListed(.ciJob(4567)) && model.isListed(.ciJob(4568)) && !model.isListed(.ciJob(1)))
            #expect(model.shortTitle(of: .ciJob(4567)) == "snapshotTest #4567")
            #expect(model.count(of: .ciJob(4567)) == model.failures.count)
            #expect(model.countLabel(of: .ciJob(4568)) == "failed, not loaded")
            #expect(model.count(of: .lastRun) == 0)                 // the fixture's last run failed nothing
            #expect(model.menuSections == [.workingCopy, .comparison, .lastRun, .run, .library, .orphaned])
            #expect(ProjectSection(id: "ci-job-4567") == .ciJob(4567) && ProjectSection(id: "last-run") == .lastRun)
            // Only looked at, for now: nothing to re-record or check for flakiness from here.
            #expect(!model.recordsFailures && model.failingSuites.isEmpty && !model.canReRecordSelection)
        }

        /// A re-record measures its progress against the tests it records: those named, else its suites'.
        @Test func aReRecordKnowsHowManyTestsItRuns() {
            let suites = [AppFixtures.checkoutSuite, AppFixtures.profileSuite]
            #expect(ProjectModel.testCount(suites: suites, onlyTesting: ["A/B/c()", "A/B/d()", "A/E/f()"]) == 3)
            #expect(ProjectModel.testCount(suites: suites, onlyTesting: nil) == suites.reduce(0) { $0 + $1.tests.count })
            #expect(ProjectModel.testCount(suites: [SuiteResult(bundle: "A", path: ["B"], tests: [], failureFiles: [])], onlyTesting: nil) == nil)
        }

        @Test func reRecordSelectionFollowsTheSection() throws {
            let model = AppFixtures.project(.library, store: AppFixtures.store())
            model.section = .library
            model.selectedSnapshotID = try #require(model.displayedSnapshots.first).id
            #expect(model.canReRecordSelection)
            model.selectedSnapshotID = try #require(AppFixtures.libraryImages.first { $0.0.testName == "oldAvatar" }).0.id
            #expect(model.selectedSnapshot?.testName == "oldAvatar")
            #expect(!model.canReRecordSelection)   // orphaned: its test is gone
            model.section = .comparison
            model.selectedChangeID = try #require(AppFixtures.changes.first { $0.0.kind == .deleted }).0.id
            #expect(model.selectedChange?.testName == "legacyHeader")
            #expect(!model.canReRecordSelection)   // nothing to record for a deleted snapshot
            model.selectedChangeID = AppFixtures.changes[0].0.id
            #expect(model.canReRecordSelection)
            model.section = .run
            #expect(!model.canReRecordSelection)
        }

        /// An orphan's test is gone, whichever section it is selected in.
        @Test func anOrphanedChangeCannotBeReRecorded() throws {
            let model = ProjectModel(project: Project(path: AppFixtures.repository.path), store: AppFixtures.store(), autoload: false)
            let orphan = try #require(AppFixtures.libraryImages.first { $0.0.testName == "oldAvatar" }).0
            var f = ProjectFixture()
            f.context = AppFixtures.context
            f.environment = AppFixtures.environment
            f.section = .comparison
            f.library = SnapshotLibrary(files: [orphan])
            f.orphanIDs = [orphan.id]
            f.changeSet = SnapshotChangeSet(baseBranch: "develop", baseRef: "develop", diffBase: .mergeBase, baseCommit: "3f1c2a9",
                                            changes: [SnapshotChange(path: orphan.path, kind: .committed)])
            model.apply(f)
            #expect(model.selectedChange?.path == orphan.path)
            #expect(!model.canReRecordSelection)
        }

        @Test func listOrderFollowsFilterScopeAndSort() {
            // The order is cached between redraws; every input has to invalidate it.
            let model = AppFixtures.project(.library, store: AppFixtures.store())
            let all = model.displayedSnapshots
            #expect(all.count == AppFixtures.libraryImages.count)
            model.libraryFilter = "payButton"
            #expect(model.displayedSnapshots.map(\.fileName) == ["payButton.dark.png", "payButton.light.png"])
            #expect(model.displayedTree.flatMap(\.suites).map(\.name) == ["CheckoutViewTests"])
            model.libraryFilter = ""
            model.section = .orphaned
            #expect(model.displayedSnapshots.map(\.testName) == ["oldAvatar"])
            model.section = .library
            model.librarySort = .size
            #expect(model.displayedSnapshots.map(\.byteSize) == all.map(\.byteSize).sorted(by: >))
            model.librarySort = .name
            #expect(model.displayedSnapshots == all)
        }

        /// Scanning a folder finds its projects and says so; nothing found is never silent.
        @Test func scanningAFolderFindsProjectsAndSaysSo() async throws {
            let root = AppFixtures.temporaryDirectory("scan")
            let repo = root.appendingPathComponent("team/app")
            let snapshots = repo.appendingPathComponent("Tests/__Snapshots__/S")
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            try Shell.output(["git", "init", "-q"], in: repo)
            try Data([1]).write(to: snapshots.appendingPathComponent("a.1.png"))   // recorded, not committed

            let app = AppModel(store: AppFixtures.store())
            await app.addDroppedFolders([root])                 // a plain folder becomes a scan folder
            for _ in 0..<200 where app.startupNotice == nil { try await Task.sleep(for: .milliseconds(50)) }
            #expect(app.store.settings.scanRoots == [root.path])
            #expect(app.projects.contains { $0.path == repo.path })
            #expect(app.startupNotice == "Found 1 project with snapshot tests in \(root.path.abbreviatingWithTildeInPath).")
        }

        @Test func scanSummaryExplainsAnEmptyOrUnreadableFolder() {
            let url = URL(fileURLWithPath: "/work")
            let none = AppModel.scanSummary([ProjectScanner.Report(root: url, projects: [], readable: true)])
            #expect(none == "No git repositories with snapshot tests in /work (looked 6 folders deep). "
                + "A repository counts when it has `__Snapshots__` images, a `.snapshotkit.yml` or depends on swift-snapshot-testing.")
            let blocked = AppModel.scanSummary([ProjectScanner.Report(root: url, projects: [], readable: false)])
            #expect(blocked == "SnapshotKit can’t read /work. "
                + "Allow it in System Settings › Privacy & Security › Files and Folders, then rescan.")
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
            #expect(model.viewedChanges == Set(AppFixtures.changes.map(\.0.id)))
            model.setAllViewed(false)
            #expect(model.viewedChanges.isEmpty)
        }

        @Test func countersShowOnlyWhenATestHasSeveralSnapshots() throws {
            let model = AppFixtures.project(.library, store: AppFixtures.store())
            let files = model.library?.files ?? []
            let named = try #require(files.first { $0.variant == "dark" })
            let lone = try #require(files.first { $0.testName == "summary" })
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
            #expect(ids("work") == ["project:/work/payments-ui", "project:/work/design-system"])   // path matches find projects
        }

        @Test func paletteOffersOnlyWhatCanBeDoneNow() {
            let app = AppModel(store: AppFixtures.store())
            #expect(PaletteCommand.available(app: app).map(\.title) == ["Add Project…"])   // no project open
            let model = AppFixtures.project(.failedRun, store: app.store)
            app.show(model)
            let titles = PaletteCommand.available(app: app).map(\.title)
            #expect(titles.contains("Re-record Failing Suites"))
            #expect(!titles.contains("Run on Remote Machine"))               // no remote machine set up
            #expect(!titles.contains("Cancel Run"))
            app.show(AppFixtures.project(.failedRun, store: app.store, remoteHost: "ci-mac"))
            #expect(PaletteCommand.available(app: app).map(\.title).contains("Run on Remote Machine"))
        }

        @Test func severalFailuresCanBeSelectedTogether() {
            let model = AppFixtures.project(.failures, store: AppFixtures.store())
            let ids = model.displayedFailures.map(\.id)
            #expect(ids.count == 2)
            model.selectedFailureID = ids[1]
            model.selectFailures(Set(ids))
            #expect(model.selectedFailureID == ids[1])                 // the focused one stays focused
            #expect(model.selectedFailures.map(\.id) == ids)          // in list order
            #expect(model.canReRecordSelection)

            model.selectFailures([ids[0]])                              // back to one
            #expect(model.selectedFailureID == ids[0])
            #expect(model.selectedFailures.map(\.id) == [ids[0]])

            model.selectFailures(Set(ids))
            model.selectedFailureID = nil                               // moved away by keyboard or a jump
            model.selectedFailureID = ids[1]
            model.failureSelection = [ids[0]]                            // a set that no longer holds the focus
            #expect(model.effectiveFailureSelection == [ids[1]])
        }

        @Test func reRecordAllCoversEveryTestButOrphans() throws {
            let app = AppModel(store: AppFixtures.store())
            let model = AppFixtures.project(.library, store: app.store)
            app.show(model)
            let files = model.recordableSnapshots
            #expect(files.count == (try #require(model.library)).files.count - 1)   // oldAvatar's test is gone
            #expect(!files.contains { model.orphanIDs.contains($0.id) })
            #expect(ProjectModel.testCount(files) == 5)                       // payButton's two variants are one test
            #expect(PaletteCommand.available(app: app).map(\.title).contains("Re-record All Snapshot Tests…"))
        }

        @Test func reRecordAllWithNothingRecordedSaysSo() {
            let model = AppFixtures.project(.empty, store: AppFixtures.store())
            #expect(model.recordableSnapshots.isEmpty)
            model.reRecordAll()
            #expect(model.lastMessageIsError)
            #expect(model.lastMessage == "No snapshot tests to re-record yet. Run the tests to record the first ones.")
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

        @Test func showInLibraryClearsFiltersThatHideTheSnapshot() throws {
            let model = AppFixtures.project(.library, store: AppFixtures.store())
            let header = try #require(AppFixtures.libraryImages.first { $0.0.testName == "header" }).0
            model.section = .orphaned
            model.libraryFilter = "payButton"
            model.showInLibrary(path: header.path)
            #expect(model.section == .library)
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
            try await waitForChanges(model)
            let change = try #require(model.changeSet?.changes.first)
            #expect(change.kind == .committed)
            #expect(!model.canDiscard(change))
        }

        @Test func droppingASubfolderAddsTheRepositoryRoot() async throws {
            let (repo, png) = try makeRepo()
            let app = AppModel(store: AppFixtures.store())
            let subfolder = repo.appendingPathComponent(png).deletingLastPathComponent()
            #expect(app.acceptsDrop([subfolder]))
            await app.addDroppedFolders([subfolder])
            #expect(app.current?.project.path == Project(path: repo.path).path)
            #expect(app.projects.contains { $0.path == Project(path: repo.path).path })
            // A file outside any repository is neither a project nor a scan folder.
            let file = AppFixtures.temporaryDirectory("loose").appendingPathExtension("txt")
            try Data("x".utf8).write(to: file)
            #expect(!app.acceptsDrop([file]))
            // A result bundle is a folder, but one to import into the open project, not to scan.
            let bundle = AppFixtures.temporaryDirectory("dropped").appendingPathExtension("xcresult")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            #expect(app.acceptsDrop([bundle]))
            await app.addDroppedFolders([bundle])
            #expect(app.store.settings.scanRoots.isEmpty)
            #expect(app.current?.lastMessage == "Reading \(bundle.lastPathComponent)…")
        }

        /// Without a project open, a result bundle has nowhere to go: the drop isn't taken.
        @Test func aResultBundleAloneNeedsAnOpenProject() throws {
            let app = AppModel(store: AppFixtures.store())
            let bundle = AppFixtures.temporaryDirectory("dropped").appendingPathExtension("xcresult")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            #expect(app.current == nil)
            #expect(!app.acceptsDrop([bundle]))
        }

        /// Two opens at once, as from two quick picks in ⌘K: the one asked for last wins, whichever folder git
        /// checks first, and the window shows it.
        @Test func ofTwoOpensTheLaterWins() async throws {
            let (first, _) = try makeRepo(), (second, _) = try makeRepo()
            let app = AppModel(store: AppFixtures.store())
            async let earlier = app.open(path: first.path)
            async let later = app.open(path: second.path)
            let opened = await [earlier, later].compactMap(\.self)
            #expect(opened.count == 1)
            #expect(app.current === opened.first)
        }

        /// A folder that is gone (or never was a repository) is not added as a project, and the window says why.
        @Test func openingAFolderOutsideAnyRepositoryIsRefused() async throws {
            let app = AppModel(store: AppFixtures.store())
            let projects = app.projects.map(\.path)
            let missing = AppFixtures.temporaryDirectory("gone").appendingPathComponent("Shop")
            #expect(await app.open(path: missing.path) == nil)
            #expect(app.startupNotice == "Can’t open \(missing.path.abbreviatingWithTildeInPath): there is no such folder.")
            let plain = AppFixtures.temporaryDirectory("plain")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            #expect(await app.open(path: plain.path) == nil)
            #expect(app.startupNotice == "Can’t open \(plain.path.abbreviatingWithTildeInPath): it isn’t in a git repository.")
            #expect(app.projects.map(\.path) == projects)
            #expect(app.current == nil)
            #expect(app.store.settings.recents == ["/work/SampleApp"])      // as AppFixtures.store() left them
        }

        /// Without git a repository can't be told from a plain folder: say git is missing, not that
        /// the folder isn't a repository.
        @Test func openingWithoutGitSaysGitIsMissing() throws {
            let (repo, _) = try makeRepo()
            #expect(AppModel.problem(opening: repo.path) == nil)
            let problem = try #require(AppModel.problem(opening: repo.path, environment: ["PATH": "/no/such/bin"]))
            #expect(problem.contains("`git` was not found on the PATH"))
            #expect(!problem.contains("isn’t in a git repository"))
            // Nor does a project already open say it is no repository any more.
            #expect(throws: CommandError.self) {
                try ProjectModel.loadContext(repo, settings: ProjectSettings(), environment: ["PATH": "/no/such/bin"])
            }
        }

        /// Each snapshot's base image gets a file of its own: two of one test, the same test name in
        /// another suite, and a base branch with a slash in its name.
        @Test func exportsBaseImageForOpeningElsewhere() async throws {
            let (repo, png) = try makeRepo()
            let second = png.replacingOccurrences(of: "card.1", with: "card.2")
            let other = png.replacingOccurrences(of: "CardTests", with: "OtherCardTests")
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(other).deletingLastPathComponent(), withIntermediateDirectories: true)
            try AppFixtures.badged.write(to: repo.appendingPathComponent(second))
            try AppFixtures.renderingNoise.write(to: repo.appendingPathComponent(other))
            let git = Git(root: repo)
            try git.run(["add", "--", second, other]); try git.run(["commit", "-qm", "more"])
            try git.run(["branch", "release/1.0"])
            for path in [second, other] { try AppFixtures.actual.write(to: repo.appendingPathComponent(path)) }

            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            // Not the temporary folder's SnapshotKit/base-images, which the app itself writes to.
            model.scratchDirectory = AppFixtures.temporaryDirectory("scratch")
            model.updateSettings { $0.baseBranch = "release/1.0" }
            try await waitForChanges(model)
            let changes = try #require(model.changeSet?.changes)
            #expect(Set(changes.map(\.path)) == [png, second, other])
            let base = [png: AppFixtures.reference, second: AppFixtures.badged, other: AppFixtures.renderingNoise]
            var urls: Set<URL> = []
            for change in changes {
                let url = try #require(model.exportBaseImage(for: change))
                urls.insert(url)
                #expect(try Data(contentsOf: url) == base[change.path])
            }
            let snapshots = model.scratchDirectory.appendingPathComponent("base-images/Tests/AppTests/__Snapshots__")
            #expect(urls == [snapshots.appendingPathComponent("CardTests/card.1 (release-1.0).png"),
                             snapshots.appendingPathComponent("CardTests/card.2 (release-1.0).png"),
                             snapshots.appendingPathComponent("OtherCardTests/card.1 (release-1.0).png")])
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
            #expect(model.context == nil)                   // nothing read yet: the window shows at once
            try await waitUntil(model.context != nil, "the configuration never loaded")
            #expect(model.context?.repository.path == repo.path)
            #expect(model.currentBranch == "feature")
            #expect(model.branches == ["develop", "feature"])
        }

        /// When the configuration breaks, the Xcode and simulator checked for it go too: nothing can
        /// run with them.
        @Test func aBrokenConfigurationForgetsTheEnvironment() async throws {
            let (repo, _) = try makeRepo()
            let model = try runnableModel(repo, xcodebuild: "exit 0")
            #expect(model.environment != nil)
            try "scheme:\n  nested: value\n".write(to: repo.appendingPathComponent(".snapshotkit.yml"), atomically: true, encoding: .utf8)
            model.reload()
            for _ in 0..<200 where model.configError == nil { try await Task.sleep(for: .milliseconds(50)) }
            #expect(model.configError != nil)
            #expect(model.environment == nil)
            #expect(model.environmentError == nil)
        }

        /// Checking Xcode again before an earlier check is done shows the later check's result,
        /// whichever finishes first.
        @Test func theLatestEnvironmentCheckWins() async throws {
            let (repo, _) = try makeRepo()
            // An Xcode whose simctl fails only once the test lets it, so the first check is still going
            // when the second one ends.
            let slow = AppFixtures.temporaryDirectory("slow").appendingPathComponent("Xcode.app")
            let xcrun = slow.appendingPathComponent("Contents/Developer/usr/bin/xcrun")
            let release = slow.appendingPathComponent("release"), asked = slow.appendingPathComponent("asked")
            try FileManager.default.createDirectory(at: xcrun.deletingLastPathComponent(), withIntermediateDirectories: true)
            // (Half a minute at most, so a test that fails before letting it go leaves no process behind.)
            try "#!/bin/sh\ni=0\nuntil [ -e '\(release.path)' ] || [ $i -ge 600 ]; do sleep 0.05; i=$((i + 1)); done\ntouch '\(asked.path)'\nexit 1\n"
                .write(to: xcrun, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "99.1"], format: .xml, options: 0)
                .write(to: slow.appendingPathComponent("Contents/version.plist"))

            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store(), autoload: false)
            var f = ProjectFixture()
            f.context = AppFixtures.context(at: repo)
            f.context?.resolved.config.developerDir = slow.path
            model.apply(f)
            let first = model.validateEnvironment()
            f.context?.resolved.config.developerDir = "/nonexistent/Xcode.app"
            model.apply(f)
            await model.validateEnvironment().value
            let missing = "Xcode at `/nonexistent/Xcode.app` does not exist. Install it there or set `xcode:` / `developerDir:` in `.snapshotkit.yml`."
            #expect(model.environmentError == missing)

            try Data().write(to: release)
            await first.value
            #expect(FileManager.default.fileExists(atPath: asked.path), "the first check never got to simctl")
            #expect(model.environmentError == missing)
            #expect(model.environment == nil)
        }

        // MARK: Selection

        /// The list groups by suite, so the first row is not the first path git reports.
        @Test func loadingSelectsTheFirstRowShown() async throws {
            let (repo, _) = try makeRepo()
            let zebra = "Modules/Zoo/Tests/__Snapshots__/ZebraTests/zebra.1.png"
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(zebra).deletingLastPathComponent(), withIntermediateDirectories: true)
            try AppFixtures.badged.write(to: repo.appendingPathComponent(zebra))
            // The last run's suites in the order they ran, not the list's.
            saveLastRun(in: repo, suites: [AppFixtures.profileSuite, AppFixtures.checkoutSuite], failed: 2)

            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            try await waitForChanges(model)
            #expect(model.displayedChanges.map(\.suite) == ["CardTests", "ZebraTests"])
            #expect(model.selectedChangeID == model.displayedChanges.first?.id)
            #expect(model.displayedFailures.map(\.suite.name) == ["CheckoutViewTests", "ProfileViewTests"])
            #expect(model.selectedFailureID == model.displayedFailures.first?.id)
        }

        func saveLastRun(in repo: URL, suites: [SuiteResult], failed: Int) {
            LastRun(result: TestRunResult(commandLine: "xcodebuild test", exitStatus: 65, cancelled: false,
                                          resultBundle: repo.appendingPathComponent("run.xcresult"), summary: TestRunSummary(suites: suites),
                                          passed: 0, failed: failed, skipped: 0, buildErrors: [])).save(repository: repo)
        }

        /// The last run as saved on disk, byte for byte, to show an operation that has no results to
        /// save left it alone.
        func savedLastRun(in repo: URL) throws -> Data {
            try Data(contentsOf: repo.appendingPathComponent(".git/snapshotkit/last-run.json"))
        }

        /// Discarding the selected change moves on to the next one, as a review goes, not back to the top.
        @Test func discardingTheSelectionSelectsTheNextOne() async throws {
            let (repo, png) = try makeRepo()
            let names = ["a", "b", "c"].map { png.replacingOccurrences(of: "card", with: $0) }
            for name in names { try AppFixtures.badged.write(to: repo.appendingPathComponent(name)) }
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            try await waitForChanges(model)
            for _ in 0..<200 where model.library?.files.count != 4 { try await Task.sleep(for: .milliseconds(50)) }
            let b = try #require(model.changeSet?.changes.first { $0.path == names[1] })
            model.selectedChangeID = b.id
            model.selectedSnapshotID = b.id

            model.discard(b)
            for _ in 0..<200 where model.library?.files.count != 3 || model.changeSet?.changes.count != 3 {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(model.selectedChangeID == names[2])
            #expect(model.selectedSnapshotID == names[2])
        }

        /// ⌥⌘↓ and a jump from the Run view focus one failure, even inside a multi-selection.
        @Test func movingTheFocusEndsAMultiSelection() {
            let model = AppFixtures.project(.failures, store: AppFixtures.store())
            let ids = model.displayedFailures.map(\.id)
            model.selectedFailureID = ids[0]
            model.selectFailures(Set(ids))
            model.selectAdjacent(1)
            #expect(model.selectedFailures.map(\.id) == [ids[1]])

            model.selectFailures(Set(ids))
            model.showFailure(ids[0])
            #expect(model.selectedFailures.map(\.id) == [ids[0]])
        }

        /// Clicking a snapshot's change mark opens that change, even when the list's filters hid it.
        @Test func showChangeClearsFiltersThatHideTheChange() throws {
            let model = AppFixtures.project(.changes, store: AppFixtures.store())
            let viewed = try #require(model.changeSet?.changes.first { model.viewedChanges.contains($0.id) })
            model.hideViewed = true
            model.changeKinds = [.committed]
            model.section = .library
            model.showChange(path: viewed.path)
            #expect(model.section == .comparison)
            #expect(model.selectedChangeID == viewed.id)
            #expect(model.displayedChanges.contains(viewed))
        }

        /// A filter, scope or Hide Viewed that hides the selection moves it to the first row shown, so
        /// the detail shows what the list does; one that matches nothing leaves it be.
        @Test func filteringKeepsTheSelectionInTheList() throws {
            let model = AppFixtures.project(.library, store: AppFixtures.store())
            let header = try #require(model.displayedSnapshots.first { $0.testName == "header" })
            model.selectedSnapshotID = header.id
            model.libraryFilter = "Profile"                 // still shown
            #expect(model.selectedSnapshotID == header.id)
            model.section = .orphaned                       // only oldAvatar's test is gone
            #expect(model.selectedSnapshot?.testName == "oldAvatar")
            model.section = .library
            #expect(model.selectedSnapshot?.testName == "oldAvatar")
            model.libraryFilter = "nothing like this"
            #expect(model.selectedSnapshot?.testName == "oldAvatar")
            model.selectAdjacent(1)                         // nothing to move to
            #expect(model.selectedSnapshot?.testName == "oldAvatar")

            let changes = AppFixtures.project(.changes, store: AppFixtures.store())
            changes.section = .comparison
            changes.selectedChangeID = try #require(changes.displayedChanges.last { $0.testName == "legacyHeader" }).id
            changes.hideViewed = true                       // legacyHeader is viewed
            #expect(changes.selectedChange?.testName == "payButton")
            changes.changeFilter = "Profile"
            #expect(changes.selectedChange?.testName == "badge")
            changes.changeKinds = [.committed]              // nothing left
            #expect(changes.selectedChange?.testName == "badge")
            changes.changeFilter = ""
            #expect(changes.selectedChange?.testName == "payButton")
        }

        // MARK: Viewed marks

        /// Marking the change on screen viewed while the list's filter hides it moves to the first unviewed one shown.
        @Test func markingAHiddenSelectionViewedMovesToTheFirstShown() throws {
            let model = AppFixtures.project(.changes, store: AppFixtures.store())
            let badge = try #require(model.displayedChanges.first { $0.testName == "badge" })
            model.selectedChangeID = badge.id
            model.changeFilter = "CheckoutViewTests"        // hides badge: the first change shown takes its place
            model.setViewed(true, for: badge)
            #expect(model.selectedChange?.testName == "payButton")
        }

        /// With Hide Viewed on, marking everything viewed leaves nothing selected: the review is done.
        @Test func markingAllViewedWhileHidingViewedEndsTheReview() {
            let model = AppFixtures.project(.changes, store: AppFixtures.store())
            model.hideViewed = true
            #expect(model.selectedChange != nil)
            model.setAllViewed(true)
            #expect(model.displayedChanges.isEmpty)
            #expect(model.selectedChange == nil)
        }

        // MARK: Refreshing

        /// Switching what to compare with several times in a row shows the last, whichever git finishes first.
        @Test func theLatestRefreshWins() async throws {
            let (repo, _) = try makeRepo()
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            try await waitForChanges(model)
            try #require(model.changeSet?.diffBase == .mergeBase)
            for _ in 0..<10 {
                // Three refreshes in flight, ending on the other diff base than the round before: a
                // refresh that never lands fails as surely as an earlier one landing last.
                let other: DiffBase = model.diffBase == .tip ? .mergeBase : .tip, start = model.diffBase
                model.diffBase = other
                model.diffBase = start
                model.diffBase = other
                try await waitUntil(!model.isLoadingChanges, "the changes never finished loading")
                #expect(model.changeSet?.diffBase == other)
            }
        }

        /// A branch checked out outside the app shows once the changes refresh (as on coming back to the app).
        @Test func aBranchCheckedOutElsewhereShowsOnRefresh() async throws {
            let (repo, _) = try makeRepo()
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            try await waitForChanges(model)
            #expect(model.currentBranch == "feature")
            try Shell.output(["git", "checkout", "-q", "-b", "release"], in: repo)
            model.refreshChanges()
            try await waitUntil(model.currentBranch == "release", "the refresh didn't read the new branch")
            #expect(model.branches.contains("release"))
        }

        /// A repository deleted while open says so when checked again, instead of looking ready to run.
        @Test func aDeletedRepositorySaysSo() async throws {
            let (repo, _) = try makeRepo()
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            try await waitUntil(model.context != nil, "the repository never opened")
            try FileManager.default.removeItem(at: repo)
            model.reload()
            try await waitUntil(model.configError != nil, "the reload didn't notice the folder is gone")
            #expect(model.context == nil)
            #expect(model.configError == "There is no folder at \(repo.path.abbreviatingWithTildeInPath) any more. Was it moved or deleted?")
        }

        /// Failures newer than the last run on disk (from an imported bundle) stay through a reload,
        /// such as choosing another base branch.
        @Test func aReloadKeepsNewerFailures() async throws {
            let (repo, _) = try makeRepo()
            var last = LastRun(result: TestRunResult(commandLine: "xcodebuild test", exitStatus: 65, cancelled: false,
                                                     resultBundle: repo.appendingPathComponent("run.xcresult"),
                                                     summary: TestRunSummary(suites: [AppFixtures.profileSuite]),
                                                     passed: 0, failed: 1, skipped: 0, buildErrors: []))
            last.date = Date().addingTimeInterval(-3600)
            last.save(repository: repo)
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store(), autoload: false)
            var f = ProjectFixture()
            f.context = AppFixtures.context(at: repo)
            f.failingSuites = [AppFixtures.checkoutSuite, AppFixtures.profileSuite]
            f.failures = AppFixtures.failures(in: AppFixtures.temporaryDirectory("failures"))
            f.failureSource = FailureSource(label: "ci.xcresult", date: Date(), host: "imported")
            model.apply(f)
            let failures = model.failures.map(\.id)
            try #require(model.changeSet == nil)

            model.setBaseBranch("develop")
            // The reload reads the last run on disk before it refreshes the changes, so changes
            // compared with develop say it has looked at that run.
            try await waitForChanges(model)
            #expect(model.changeSet?.baseBranch == "develop")
            #expect(model.failures.map(\.id) == failures)
            #expect(model.failureSource == f.failureSource)
        }

        /// Coming back to the app after running the tests in `snapkit` shows that run.
        @Test func aRunInSnapkitShowsWhenTheAppIsActiveAgain() async throws {
            let (repo, _) = try makeRepo()
            var earlier = LastRun(result: AppFixtures.lastResult)
            earlier.date = Date().addingTimeInterval(-60)     // saved to the second
            earlier.save(repository: repo)
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            for _ in 0..<200 where model.failures.count != 2 { try await Task.sleep(for: .milliseconds(50)) }
            try #require(model.failingSuites.count == 2)

            saveLastRun(in: repo, suites: [AppFixtures.profileSuite], failed: 1)
            await model.refreshAfterActivation().value
            #expect(model.failingSuites.map(\.identifier) == [AppFixtures.profileSuite.identifier])
            #expect(model.failures.map(\.suite.identifier) == [AppFixtures.profileSuite.identifier])
        }

        /// Coming back to the app after its own verification saved the last run reads nothing again:
        /// the flakiness verdicts and the Run view's result stay. (They went, as the app's save looked
        /// like a run in `snapkit`.) A run saved elsewhere since is read.
        @Test func comingBackAfterTheAppsOwnSaveKeepsWhatItShows() async throws {
            let repo = try makeRecordableRepo(suite: "CheckoutViewTests")
            var earlier = LastRun(result: AppFixtures.lastResult)
            earlier.date = Date().addingTimeInterval(-3600)
            earlier.save(repository: repo)
            let model = try await loadedModel(repo, xcodebuild: "exit 65", testResults: Self.payButtonFailed)
            let payButton = "AppSnapshotTests/CheckoutViewTests/payButton()", badge = "AppSnapshotTests/ProfileViewTests/badge()"
            #expect(model.failures.map(\.id) == [payButton, badge])

            model.checkFlakiness(tests: [payButton])
            try await waitUntilFinished(model)
            let verdicts = model.flakeResults
            #expect(verdicts.map(\.id) == [payButton])
            model.reRecord(failures: [try #require(model.failures.first { $0.id == payButton })])
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Re-recorded payButton(). Verification still fails (1) — the test may be flaky; try Check Flakiness.")
            let verification = try #require(model.lastResult)
            // The verification saved the last run: newer than the failures shown, as a run elsewhere would be.
            #expect(try #require(LastRun.load(repository: repo)).date > (try #require(model.failureSource)).date)

            await model.refreshAfterActivation().value
            #expect(model.flakeResults == verdicts)
            #expect(model.lastResult?.resultBundle == verification.resultBundle)
            #expect(model.failures.map(\.id) == [payButton, badge])
            // Nor does a reload (a settings change, Check Again) take the app's own save for an outside run.
            await model.reload().value
            #expect(model.flakeResults == verdicts)
            #expect(model.lastResult?.resultBundle == verification.resultBundle)

            LastRun.update(with: TestRunResult(commandLine: "xcodebuild test", exitStatus: 65, cancelled: false,
                                               resultBundle: repo.appendingPathComponent("snapkit.xcresult"),
                                               summary: TestRunSummary(suites: [AppFixtures.profileSuite]),
                                               passed: 0, failed: 1, skipped: 0, buildErrors: []),
                           repository: repo)              // as `snapkit run` saves it
            await model.refreshAfterActivation().value
            #expect(model.lastResult == nil)
            #expect(model.flakeResults.isEmpty)
            #expect(model.failures.map(\.id) == [badge])
        }

        /// A project added while the counts are being read gets its count too.
        @Test func failingCountsCoverAProjectAddedWhileCounting() async throws {
            let reads = AppModel.readsFailingCounts
            AppModel.readsFailingCounts = true        // snapshot tests leave the counts out
            defer { AppModel.readsFailingCounts = reads }
            let (repo, _) = try makeRepo()
            saveLastRun(in: repo, suites: [], failed: 2)
            let app = AppModel(store: AppFixtures.store())     // starts counting the projects it knows
            await app.open(path: repo.path)
            for _ in 0..<200 where app.failingCounts[repo.path] == nil { try await Task.sleep(for: .milliseconds(50)) }
            #expect(app.failingCounts[repo.path] == 2)
        }

        // MARK: Operations

        /// A model of `repo` that can run, with `script` as xcodebuild.
        func runnableModel(_ repo: URL, xcodebuild script: String, testResults: String? = nil, attachments: URL? = nil,
                           failures: Bool = false, flakeResults: [FlakeResult] = [], library: [SnapshotFile] = []) throws -> ProjectModel {
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store(), autoload: false)
            var f = ProjectFixture()
            f.context = AppFixtures.context(at: repo)
            f.environment = try AppFixtures.fakeXcode(script, testResults: testResults, attachments: attachments)
            f.section = .lastRun
            if failures {
                f.lastResult = AppFixtures.lastResult
                f.failingSuites = [AppFixtures.checkoutSuite, AppFixtures.profileSuite]
                f.failures = AppFixtures.failures(in: AppFixtures.temporaryDirectory("failures"))
            }
            f.flakeResults = flakeResults
            if !library.isEmpty { f.library = SnapshotLibrary(files: library) }
            model.apply(f)
            return model
        }

        /// A model of `repo` loaded as the app loads one, from the repository rather than a fixture,
        /// whose `.snapshotkit.yml` names a fake Xcode with `script` as xcodebuild (see `AppFixtures.fakeXcode`).
        /// `pinning`: the Xcode version the configuration pins as well.
        func loadedModel(_ repo: URL, xcodebuild script: String, testResults: String? = nil,
                         pinning version: String? = nil) async throws -> ProjectModel {
            let xcode = try AppFixtures.fakeXcode(script, testResults: testResults).xcode
            try """
                developerDir: \(xcode.path)
                scheme: SampleApp
                device: Example Phone
                os: "99.0"
                baseBranch: develop
                \(version.map { "xcode: \"\($0)\"" } ?? "")
                """.write(to: repo.appendingPathComponent(".snapshotkit.yml"), atomically: true, encoding: .utf8)
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            try await waitUntil(model.environment != nil || model.environmentError != nil || model.configError != nil,
                                "Xcode was never checked")
            try #require(model.environment?.xcode.path == xcode.path, "\(model.configError ?? model.environmentError ?? "")")
            return model
        }

        /// xcodebuild that says it started, then runs until cancelled.
        static let longRun = "echo 'Testing started'\nexec sleep 60"

        func waitUntilStarted(_ model: ProjectModel) async throws {
            for _ in 0..<200 where !model.log.contains("Testing started") { try await Task.sleep(for: .milliseconds(50)) }
            try #require(model.log.contains("Testing started"))
        }

        func waitUntilFinished(_ model: ProjectModel) async throws {
            for _ in 0..<400 where model.isRunning { try await Task.sleep(for: .milliseconds(50)) }
            try #require(!model.isRunning)
        }

        /// While one operation runs, another is refused, not queued (the menus and ⌘K offer none then):
        /// the run carries on with its progress shown, and nothing else starts once it ends.
        @Test func aSecondOperationIsRefusedWhileOneRuns() async throws {
            let (repo, _) = try makeRepo()
            let model = try runnableModel(repo, xcodebuild: "echo \"$@\" >> \"$0.args\"\n" + Self.longRun, failures: true)
            model.runTests()
            try await waitUntilStarted(model)
            model.reRecordFailed()
            model.reRecord(failures: model.failures)
            model.checkFlakiness()
            #expect(model.operation == .run)
            #expect(model.stageLabel == RunOperation.run.label)
            #expect(model.lastMessage == nil)
            model.cancel()
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Cancelled.")
            #expect(!model.isRunning)
            let xcodebuild = try #require(model.environment).xcode.developerDir + "/usr/bin/xcrun.args"
            #expect(try String(contentsOfFile: xcodebuild, encoding: .utf8).split(separator: "\n").count == 1)
        }

        @Test func cancellingBeforeXcodebuildStartsIsNoError() async throws {
            let (repo, _) = try makeRepo()
            let model = try runnableModel(repo, xcodebuild: Self.longRun)
            model.runTests()
            model.cancel()                      // xcodebuild hasn't started yet
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Cancelled.")
            #expect(!model.lastMessageIsError)
        }

        /// A cancelled run has no results; the last run's failures stay, here and on disk.
        @Test func cancellingARunKeepsTheLastRunsFailures() async throws {
            let (repo, _) = try makeRepo()
            saveLastRun(in: repo, suites: [AppFixtures.checkoutSuite, AppFixtures.profileSuite], failed: 2)
            let saved = try savedLastRun(in: repo)
            let model = try runnableModel(repo, xcodebuild: Self.longRun, failures: true)
            let failures = model.failures.map(\.id)
            let last = try #require(model.lastResult)
            let counts = (model.passed, model.failed, model.skipped)
            let runs = RunHistory(repository: repo).load().count
            model.runTests()
            try await waitUntilStarted(model)
            model.cancel()
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Cancelled.")
            #expect(model.lastMessageIsCancellation)                 // neither passed nor failed
            #expect(model.failures.map(\.id) == failures)
            // The Run view shows the last run as before, not the cancelled run's few results.
            #expect(model.lastResult?.resultBundle == last.resultBundle)
            #expect((model.passed, model.failed, model.skipped) == counts)
            #expect(RunHistory(repository: repo).load().count == runs)
            #expect(model.failingSuites.map(\.identifier) == [AppFixtures.checkoutSuite.identifier, AppFixtures.profileSuite.identifier])
            #expect(try savedLastRun(in: repo) == saved)
        }

        /// A re-record's progress is measured against the tests it records, not the last full run's count.
        @Test func reRecordingForgetsTheLastRunsTotal() async throws {
            let (repo, _) = try makeRepo()
            let model = try runnableModel(repo, xcodebuild: Self.longRun, failures: true)
            model.runTests()                    // expects as many tests as the last run had
            #expect(model.expectedTotal == 3)
            model.cancel()
            try await waitUntilFinished(model)
            let recorded = model.failingSuites.reduce(0) { $0 + $1.tests.count }
            model.reRecordFailed()
            #expect(model.isRunning)
            #expect(recorded > 0 && model.expectedTotal == recorded)
            model.cancel()
            try await waitUntilFinished(model)
        }

        /// A run's progress is measured against the last run of every test, not a flakiness check of one.
        @Test func aRunExpectsAsManyTestsAsTheLastFullRun() async throws {
            let (repo, _) = try makeRepo()
            let model = try runnableModel(repo, xcodebuild: "exit 65", testResults: Self.payButtonFailed, failures: true)
            model.checkFlakiness(tests: [AppFixtures.checkoutSuite.identifier + "/payButton()"])
            try await waitUntilFinished(model)
            #expect(model.lastResult?.summary?.total == 1)
            model.runTests()
            #expect(model.expectedTotal == 3)
            try await waitUntilFinished(model)
        }

        /// A repo whose CardTests suite can be patched into record mode.
        func makeRecordableRepo(suite: String = "CardTests") throws -> URL {
            let (repo, _) = try makeRepo()
            let source = "Tests/AppTests/\(suite).swift"
            try """
            import SnapshotTesting
            import Testing

            @Suite(.snapshots(record: .missing))
            struct \(suite) {
                @Test func card() {}
            }
            """.write(to: repo.appendingPathComponent(source), atomically: true, encoding: .utf8)
            try Shell.output(["git", "add", "--", source], in: repo)
            try Shell.output(["git", "commit", "-qm", "suite", "--", source], in: repo)
            return repo
        }

        /// xcresulttool's report of a run in which card() passed.
        static let cardPassed = """
            {"testNodes": [{"name": "AppTests", "nodeType": "Unit test bundle", "children": [
              {"name": "CardTests", "nodeType": "Test Suite", "children": [
                {"name": "card()", "nodeType": "Test Case", "nodeIdentifier": "CardTests/card()", "result": "Passed"}]}]}]}
            """

        static let cardSuite = SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [
            TestCaseResult(name: "card()", identifier: "CardTests/card()", outcome: .failed, failureMessages: [], repetitions: [.failed]),
        ], failureFiles: [])

        @Test func cancellingAReRecordSaysSo() async throws {
            let repo = try makeRecordableRepo()
            let model = try runnableModel(repo, xcodebuild: Self.longRun, failures: true)
            let shown = (model.lastResult?.resultBundle, model.passed, model.failed, model.lastDuration)
            model.reRecordFailed(suites: [Self.cardSuite])
            try await waitUntilStarted(model)
            model.cancel()
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Cancelled.")
            // The Run view shows what it did before: not the cancelled record run, nor its duration.
            #expect(model.lastResult?.resultBundle == shown.0)
            #expect((model.passed, model.failed, model.lastDuration) == (shown.1, shown.2, shown.3))
            #expect(try Shell.output(["git", "status", "--porcelain", "--", "Tests/AppTests/CardTests.swift"], in: repo).isEmpty)
        }

        /// Cancelling the verification after a re-record leaves the failures as they were.
        @Test func cancellingTheVerificationKeepsTheFailures() async throws {
            let repo = try makeRecordableRepo()
            saveLastRun(in: repo, suites: [AppFixtures.checkoutSuite, AppFixtures.profileSuite], failed: 2)
            let saved = try savedLastRun(in: repo)
            // Records at once; the second run, the verification, waits.
            let model = try runnableModel(repo, xcodebuild: "[ -e \"$0.ran\" ] || { touch \"$0.ran\"; exit 0; }\n" + Self.longRun,
                                          testResults: Self.cardPassed, failures: true)
            let failures = model.failures.map(\.id)
            let shown = model.lastResult?.resultBundle
            model.reRecordFailed(suites: [Self.cardSuite])
            try await waitUntilStarted(model)
            model.cancel()
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Re-recorded CardTests. The verification was cancelled.")
            #expect(model.failures.map(\.id) == failures)
            #expect(model.lastResult?.resultBundle == shown)               // not the cancelled verification
            #expect(try savedLastRun(in: repo) == saved)
        }

        /// When the tests don't build, nothing was re-recorded: say why, and keep the failures.
        @Test func aReRecordThatDoesNotBuildSaysSo() async throws {
            let repo = try makeRecordableRepo()
            let model = try runnableModel(repo, xcodebuild: """
                echo "\(repo.path)/Tests/AppTests/CardTests.swift:7:9: error: cannot find 'card' in scope"
                exit 65
                """, failures: true)
            let failures = model.failures.map(\.id)
            model.reRecordFailed(suites: [Self.cardSuite])
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Nothing was recorded: the build failed (CardTests.swift:7:9: cannot find 'card' in scope).")
            #expect(model.lastMessageIsError)
            #expect(model.lastMessageAction == nil)
            #expect(model.failures.map(\.id) == failures)
        }

        /// The verification after re-recording one of two failing tests runs just that one: the
        /// other still fails, here, on disk and in the counts.
        @Test func verifyingOneTestKeepsTheOtherFailures() async throws {
            let repo = try makeRecordableRepo(suite: "CheckoutViewTests")
            saveLastRun(in: repo, suites: [AppFixtures.checkoutSuite, AppFixtures.profileSuite], failed: 2)
            let model = try runnableModel(repo, xcodebuild: "exit 0", testResults: """
                {"testNodes": [{"name": "AppSnapshotTests", "nodeType": "Unit test bundle", "children": [
                  {"name": "CheckoutViewTests", "nodeType": "Test Suite", "children": [
                    {"name": "payButton()", "nodeType": "Test Case", "nodeIdentifier": "CheckoutViewTests/payButton()", "result": "Passed"}]}]}]}
                """, failures: true)
            let payButton = try #require(model.failures.first { $0.test.name == "payButton()" })
            let badge = try #require(model.failures.first { $0.test.name == "badge()" })

            model.reRecord(failures: [payButton])
            #expect(model.operation == .rerecord)
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Re-recorded payButton(). Verified: 1 passed.")
            #expect(model.failures.map(\.id) == [badge.id])
            #expect(model.failures.first?.images == badge.images)
            #expect(model.failingSuites.map(\.identifier) == [AppFixtures.profileSuite.identifier])
            let last = try #require(LastRun.load(repository: repo))
            #expect(last.failed == 1)
            #expect(last.failingSuites.map(\.identifier) == [AppFixtures.profileSuite.identifier])
        }

        /// xcresulttool's report of a run in which payButton() failed.
        static let payButtonFailed = """
            {"testNodes": [{"name": "AppSnapshotTests", "nodeType": "Unit test bundle", "children": [
              {"name": "CheckoutViewTests", "nodeType": "Test Suite", "children": [
                {"name": "payButton()", "nodeType": "Test Case", "nodeIdentifier": "CheckoutViewTests/payButton()", "result": "Failed",
                 "children": [{"name": "Snapshot does not match reference.", "nodeType": "Failure Message", "result": "Failed"}]}]}]}]}
            """

        /// xcodebuild whose first run (the record) passes and whose later ones (the verification) fail.
        static let recordsThenFails = "[ -e \"$0.ran\" ] || { touch \"$0.ran\"; exit 0; }\nexit 65"

        /// A folder as `xcresulttool export attachments` leaves it: payButton()'s reference and actual image.
        func payButtonAttachments() throws -> URL {
            let dir = AppFixtures.temporaryDirectory("attachments")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try AppFixtures.reference.write(to: dir.appendingPathComponent("reference_0_A.png"))
            try AppFixtures.actual.write(to: dir.appendingPathComponent("failure_0_B.png"))
            try Data("""
                [{"testIdentifier": "CheckoutViewTests/payButton()", "attachments": [
                  {"exportedFileName": "reference_0_A.png", "suggestedHumanReadableName": "reference_0_A.png"},
                  {"exportedFileName": "failure_0_B.png", "suggestedHumanReadableName": "failure_0_B.png"}]}]
                """.utf8).write(to: dir.appendingPathComponent("manifest.json"))
            return dir
        }

        /// A flakiness check moves on to the failures when it ends only if the user is still where
        /// they started it; otherwise the notice offers them.
        @Test func aFinishedCheckLeavesAUserWhoMovedOnWhereTheyAre() async throws {
            let (repo, _) = try makeRepo()
            let app = AppModel(store: AppFixtures.store())
            let model = try runnableModel(repo, xcodebuild: "exit 0", testResults: Self.payButtonFailed, failures: true)
            app.show(model)
            model.section = .run
            model.checkFlakiness()
            try await waitUntilFinished(model)
            #expect(model.section == .lastRun)

            model.section = .run
            model.checkFlakiness()
            model.section = .comparison                            // moved to another section meanwhile
            try await waitUntilFinished(model)
            #expect(model.section == .comparison)
            #expect(model.lastMessageAction == .showFailures(.lastRun))

            model.section = .run
            model.checkFlakiness()
            app.show(AppFixtures.project(.library, store: app.store))   // and to another project
            try await waitUntilFinished(model)
            #expect(model.section == .run)
        }

        /// A project removed while it runs keeps running, and its model goes once the run ends.
        @Test func aProjectRemovedWhileRunningIsLetGoWhenItEnds() async throws {
            let (repo, _) = try makeRepo()
            let app = AppModel(store: AppFixtures.store())
            let model = try runnableModel(repo, xcodebuild: Self.longRun)
            app.show(model)
            model.runTests()
            try await waitUntilStarted(model)
            app.remove(model.project)
            #expect(app.projectModel(path: model.project.path) === model)
            model.cancel()
            try await waitUntilFinished(model)
            try await waitUntil(app.projectModel(path: model.project.path) == nil, "the project was kept after its run")
            #expect(app.runningPaths.isEmpty)
        }

        /// A run counts its passed tests right, and one in which no test ran says so.
        @Test func aRunSaysHowManyTestsPassed() async throws {
            let (repo, _) = try makeRepo()
            let one = try runnableModel(repo, xcodebuild: "exit 0", testResults: Self.cardPassed)
            one.runTests()
            try await waitUntilFinished(one)
            #expect(one.lastMessage == "1 test passed.")

            let none = try runnableModel(repo, xcodebuild: "exit 0")     // no results, no test output
            none.runTests()
            try await waitUntilFinished(none)
            #expect(none.lastMessage == "No test ran.")
            #expect(none.lastMessageIsError)
        }

        /// A run whose tests don't build found out nothing about them: the failures stay, here and on disk.
        @Test func aRunThatDoesNotBuildKeepsTheFailures() async throws {
            let (repo, _) = try makeRepo()
            saveLastRun(in: repo, suites: [AppFixtures.checkoutSuite, AppFixtures.profileSuite], failed: 2)
            let model = try runnableModel(repo, xcodebuild: """
                echo "\(repo.path)/Tests/AppTests/CardTests.swift:7:9: error: cannot find 'card' in scope"
                exit 65
                """, failures: true)
            let failures = model.failures.map(\.id)
            model.runTests()
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Build failed: CardTests.swift:7:9: cannot find 'card' in scope")
            #expect(model.failures.map(\.id) == failures)
            #expect(model.failingSuites.count == 2)
            #expect(LastRun.load(repository: repo)?.failed == 2)
        }

        /// A run with failing tests says how many, in how many suites, offers to show them, shows
        /// them with their images and saves them as the last run. The verdicts of earlier flakiness
        /// checks go: they were of other runs.
        @Test func aFailingRunShowsItsFailures() async throws {
            let (repo, _) = try makeRepo()
            let earlier = FlakeResult(suite: AppFixtures.profileSuite.identifier, test: "badge()", passed: 5, failed: 0, verdict: .passes)
            let model = try runnableModel(repo, xcodebuild: "exit 65", testResults: Self.payButtonFailed,
                                          attachments: try payButtonAttachments(), failures: true, flakeResults: [earlier])
            model.runTests()
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "1 failing test in 1 suite")
            #expect(model.lastMessageIsError)
            #expect(model.lastMessageAction == .showFailures(.lastRun))
            #expect(model.flakeResults.isEmpty)
            #expect(model.failures.map(\.id) == ["AppSnapshotTests/CheckoutViewTests/payButton()"])
            let failure = try #require(model.failures.first?.images.first?.failure)
            #expect(try Data(contentsOf: failure) == AppFixtures.actual)
            let source = try #require(model.failureSource)
            #expect(source == FailureSource(label: "Local run", date: source.date, host: "local", resultBundle: model.lastResult?.resultBundle))
            let last = try #require(LastRun.load(repository: repo))
            #expect((last.passed, last.failed) == (0, 1))
            #expect(last.failingSuites.map(\.identifier) == [AppFixtures.checkoutSuite.identifier])
        }

        /// Re-recording a snapshot records just its test, then verifies it. One whose test isn't in
        /// the repository says so, and nothing runs.
        @Test func reRecordingASnapshotRecordsItsTest() async throws {
            let repo = try makeRecordableRepo()
            let model = try runnableModel(repo, xcodebuild: "echo \"$@\" >> \"$0.args\"\nexit 0", testResults: Self.cardPassed)
            model.reRecord([SnapshotFile(path: "Tests/AppTests/__Snapshots__/CardTests/card.1.png", byteSize: 0)], granularity: .tests)
            try await waitUntil(model.isRunning, "the re-record never started")
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Re-recorded card. Verified: 1 passed.")
            #expect(model.lastMessageAction == .reviewChanges)
            let xcodebuild = try #require(model.environment).xcode.developerDir + "/usr/bin/xcrun.args"
            let runs = try String(contentsOfFile: xcodebuild, encoding: .utf8).split(separator: "\n")
            #expect(runs.count == 2)                        // the record and the verification
            for run in runs { #expect(run.contains("-only-testing:AppTests/CardTests/card()")) }

            let said = model.messageID
            model.reRecord([SnapshotFile(path: "Tests/AppTests/__Snapshots__/GoneTests/old.1.png", byteSize: 0)], granularity: .tests)
            try await waitUntil(model.messageID != said, "the re-record never said why it can't")
            #expect(model.lastMessage == "Can’t re-record: Could not find the source file for suite “AppTests/GoneTests”.")
            #expect(model.lastMessageIsError)
            #expect(!model.isRunning)
            #expect(try String(contentsOfFile: xcodebuild, encoding: .utf8).split(separator: "\n").count == 2)
        }

        /// Re-record All records every test that has a snapshot (one each, however many it has), then verifies.
        @Test func reRecordAllRecordsEveryTest() async throws {
            let repo = try makeRecordableRepo()
            let snapshots = ["card.1.png", "card.2.png"].map { SnapshotFile(path: "Tests/AppTests/__Snapshots__/CardTests/" + $0, byteSize: 0) }
            let model = try runnableModel(repo, xcodebuild: "echo \"$@\" >> \"$0.args\"\nexit 0", testResults: Self.cardPassed,
                                          library: snapshots)
            model.reRecordAll()
            try await waitUntil(model.isRunning, "the re-record never started")
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Re-recorded card. Verified: 1 passed.")
            let xcodebuild = try #require(model.environment).xcode.developerDir + "/usr/bin/xcrun.args"
            let runs = try String(contentsOfFile: xcodebuild, encoding: .utf8).split(separator: "\n")
            #expect(runs.count == 2)
            for run in runs {
                #expect(run.contains("-only-testing:AppTests/CardTests/card()"))
                #expect(run.components(separatedBy: "-only-testing:").count == 2, "only card(), once: \(run)")
            }
        }

        /// A test with a display name (`@Test("Shows card")`) shows by it, and is addressed by its
        /// identifier: its flakiness verdict lands on it, and re-recording it runs `CardTests/card()`.
        /// The display name is what real result bundles put in a test's name.
        @Test func aTestWithADisplayNameIsRunByItsIdentifier() async throws {
            let repo = try makeRecordableRepo()
            let model = try runnableModel(repo, xcodebuild: "echo \"$@\" >> \"$0.args\"\nexit 65", testResults: """
                {"testNodes": [{"name": "AppTests", "nodeType": "Unit test bundle", "children": [
                  {"name": "Card views", "nodeType": "Test Suite", "nodeIdentifierURL": "test://com.apple.xcode/App/AppTests/CardTests", "children": [
                    {"name": "Shows card", "nodeType": "Test Case", "nodeIdentifier": "CardTests/card()", "result": "Failed",
                     "children": [{"name": "Snapshot does not match reference.", "nodeType": "Failure Message", "result": "Failed"}]}]}]}]}
                """)
            model.runTests()
            try await waitUntilFinished(model)
            let card = try #require(model.failures.first)
            #expect(model.failures.map(\.id) == ["AppTests/CardTests/card()"])
            #expect(card.test.name == "Shows card")

            model.checkFlakiness(tests: [card.id])
            try await waitUntilFinished(model)
            #expect(model.failures.first?.verdict == .alwaysFails)

            model.reRecord(failures: model.failures)
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Re-recorded Shows card. Verification still fails (1) — the test may be flaky; try Check Flakiness.")
            let xcodebuild = try #require(model.environment).xcode.developerDir + "/usr/bin/xcrun.args"
            let runs = try String(contentsOfFile: xcodebuild, encoding: .utf8).split(separator: "\n")
            #expect(runs.count == 4)                        // the run, the check, the record and the verification
            for run in runs {
                #expect(run.contains("-only-testing:AppTests/CardTests/card()") == (run != runs[0]), "\(run)")
                #expect(!run.contains("Shows card"))
            }
        }

        /// The environment's notes come with it: here, that the Xcode at `developerDir` isn't the
        /// version the configuration pins as well.
        @Test func theXcodeChecksNotesShow() async throws {
            let (repo, _) = try makeRepo()
            let model = try await loadedModel(repo, xcodebuild: "exit 0", pinning: "99.2")
            let xcode = try #require(model.environment).xcode
            #expect(model.environmentNotes == [
                "Using Xcode 99.1 at `\(xcode.path)` (`developerDir`, from .snapshotkit.yml), not Xcode 99.2 as pinned by .snapshotkit.yml: "
                    + "snapshots may differ from CI’s.",
            ])
        }

        /// A flakiness check's summary reads right for one test.
        @Test func aFlakinessCheckOfOneTestReadsRight() async throws {
            let (repo, _) = try makeRepo()
            let model = try runnableModel(repo, xcodebuild: "exit 65", testResults: Self.payButtonFailed, failures: true)
            model.checkFlakiness(tests: [AppFixtures.checkoutSuite.identifier + "/payButton()"])
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "5× on local: 1 fails every time, 0 flaky, 0 pass.")
        }

        /// A test that fails every time on one simulator and passes on the other is not called flaky:
        /// it fails on that one.
        @Test func aTestFailingOnOneDeviceIsNotFlaky() async throws {
            let (repo, _) = try makeRepo()
            let model = try runnableModel(repo, xcodebuild: "exit 65", testResults: """
                {"devices": [{"deviceId": "A", "deviceName": "iPhone SE"}, {"deviceId": "B", "deviceName": "iPhone 18 Pro"}],
                 "testNodes": [{"name": "AppSnapshotTests", "nodeType": "Unit test bundle", "children": [
                  {"name": "CheckoutViewTests", "nodeType": "Test Suite", "children": [
                    {"name": "payButton()", "nodeType": "Test Case", "nodeIdentifier": "CheckoutViewTests/payButton()", "result": "Failed", "children": [
                      {"name": "iPhone SE", "nodeIdentifier": "A", "nodeType": "Device", "children": [
                        {"nodeType": "Repetition", "name": "1", "result": "Failed"}, {"nodeType": "Repetition", "name": "2", "result": "Failed"}]},
                      {"name": "iPhone 18 Pro", "nodeIdentifier": "B", "nodeType": "Device", "children": [
                        {"nodeType": "Repetition", "name": "1", "result": "Passed"}, {"nodeType": "Repetition", "name": "2", "result": "Passed"}]}]}]}]}]}
                """, failures: true)
            model.checkFlakiness(tests: [AppFixtures.checkoutSuite.identifier + "/payButton()"])
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "5× on local: 0 fail every time, 1 only on some devices, 0 flaky, 0 pass.")
            let payButton = try #require(model.failures.first { $0.test.name == "payButton()" })
            #expect(payButton.verdict == .alwaysFails)
            #expect(payButton.verdictLabel == "Fails on iPhone SE")
        }

        /// A flakiness check whose tests don't build says so, and keeps the verdicts.
        @Test func aFlakinessCheckThatDoesNotBuildSaysSo() async throws {
            let (repo, _) = try makeRepo()
            let model = try runnableModel(repo, xcodebuild: """
                echo "\(repo.path)/Tests/AppTests/CardTests.swift:7:9: error: cannot find 'card' in scope"
                exit 65
                """, failures: true)
            let verdicts = model.failures.map(\.verdict)
            let shown = (model.passed, model.failed, model.skipped, model.lastDuration, model.resultSuites)
            model.checkFlakiness()
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Nothing was checked: the build failed (CardTests.swift:7:9: cannot find 'card' in scope).")
            #expect(model.lastMessageIsError)
            #expect(model.failures.map(\.verdict) == verdicts)
            // Nothing new to show: the Run view's counts and results stay those of the last run.
            #expect((model.passed, model.failed, model.skipped, model.lastDuration) == (shown.0, shown.1, shown.2, shown.3))
            #expect(model.resultSuites == shown.4)
        }

        /// Checking one test again says what that check found, not what earlier checks of other tests did.
        @Test func aFlakinessCheckCountsOnlyTheTestsItChecked() async throws {
            let (repo, _) = try makeRepo()
            let earlier = FlakeResult(suite: AppFixtures.profileSuite.identifier, test: "badge()", passed: 5, failed: 0, verdict: .passes)
            let model = try runnableModel(repo, xcodebuild: "exit 65", testResults: Self.payButtonFailed, failures: true,
                                          flakeResults: [earlier])
            model.checkFlakiness(tests: [AppFixtures.checkoutSuite.identifier + "/payButton()"])
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "5× on local: 1 fails every time, 0 flaky, 0 pass.")
            #expect((model.passed, model.failed) == (0, 1))
            // The earlier verdict stays, next to the new one.
            #expect(model.flakeResults == [FlakeResult(suite: AppFixtures.checkoutSuite.identifier, test: "payButton()",
                                                       identifier: "AppSnapshotTests/CheckoutViewTests/payButton()",
                                                       passed: 0, failed: 1, verdict: .alwaysFails),
                                           earlier])
        }

        /// A cancelled flakiness check says so and leaves the verdicts as they were, as a cancelled run does.
        @Test func cancellingAFlakinessCheckKeepsTheVerdicts() async throws {
            let (repo, _) = try makeRepo()
            let model = try runnableModel(repo, xcodebuild: Self.longRun, testResults: Self.payButtonFailed, failures: true)
            let verdicts = model.failures.map(\.verdict)
            model.checkFlakiness()
            try await waitUntilStarted(model)
            model.cancel()
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Cancelled.")
            #expect(model.failures.map(\.verdict) == verdicts)
        }

        /// A verification in which no test ran verified nothing: it says so rather than calling the test
        /// flaky, and leaves the failures as they were.
        @Test func aVerificationThatRanNoTestSaysSo() async throws {
            let repo = try makeRecordableRepo()
            saveLastRun(in: repo, suites: [AppFixtures.checkoutSuite, AppFixtures.profileSuite], failed: 2)
            let saved = try savedLastRun(in: repo)
            let model = try runnableModel(repo, xcodebuild: """
                [ -e "$0.ran" ] || { touch "$0.ran"; exit 0; }
                for arg; do [ "$p" = -resultBundlePath ] && rm -rf "$arg"; p=$arg; done
                exit 65
                """, testResults: Self.cardPassed, failures: true)
            let failures = model.failures.map(\.id)
            model.reRecordFailed(suites: [Self.cardSuite])
            #expect(model.operation == .rerecord)
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Re-recorded CardTests. Could not verify: no test ran.")
            #expect(model.lastMessageIsError)
            #expect(model.failures.map(\.id) == failures)
            #expect(try savedLastRun(in: repo) == saved)
        }

        /// The Dock badge counts the failing tests, not a flakiness check's failed repetitions.
        @Test func theDockBadgeCountsFailingTests() async throws {
            let (repo, _) = try makeRepo()
            // payButton() fails in 3 of 5 repetitions; badge() still fails too.
            let model = try runnableModel(repo, xcodebuild: "exit 65", testResults: """
                {"testNodes": [{"name": "AppSnapshotTests", "nodeType": "Unit test bundle", "children": [
                  {"name": "CheckoutViewTests", "nodeType": "Test Suite", "children": [
                    {"name": "payButton()", "nodeType": "Test Case", "nodeIdentifier": "CheckoutViewTests/payButton()", "result": "Failed",
                     "children": [{"nodeType": "Repetition", "name": "1", "result": "Failed"}, {"nodeType": "Repetition", "name": "2", "result": "Passed"},
                                  {"nodeType": "Repetition", "name": "3", "result": "Failed"}, {"nodeType": "Repetition", "name": "4", "result": "Passed"},
                                  {"nodeType": "Repetition", "name": "5", "result": "Failed"}]}]}]}]}
                """, failures: true)
            model.checkFlakiness(tests: [AppFixtures.checkoutSuite.identifier + "/payButton()"])
            try await waitUntilFinished(model)
            #expect(model.failures.count == 2)
            #expect(model.dockBadge == "2")
        }

        /// An import that fails says why as soon as it has (a capture waits for it, then stops).
        @Test func aFailedImportSaysWhy() async throws {
            let (repo, _) = try makeRepo()
            let model = try runnableModel(repo, xcodebuild: "exit 0", failures: true)    // its xcresulttool reads no bundle
            let failures = model.failures.map(\.id)
            let bundle = AppFixtures.temporaryDirectory("missing").appendingPathExtension("xcresult")
            await model.importResultBundle(bundle).value
            #expect(model.lastMessageIsError)
            #expect(model.lastMessage == "Could not read \(bundle.lastPathComponent): `xcresulttool get test-results tests` exited with 1")
            #expect(model.failures.map(\.id) == failures)
        }

        /// An imported bundle's failures replace the ones shown, with their images, as a run's would;
        /// the verdicts of earlier checks go (they were of other runs), the history has the import,
        /// and the failures show it.
        @Test func anImportShowsTheBundlesFailures() async throws {
            let (repo, _) = try makeRepo()
            let app = AppModel(store: AppFixtures.store())
            let earlier = FlakeResult(suite: AppFixtures.profileSuite.identifier, test: "badge()", passed: 5, failed: 0, verdict: .passes)
            let model = try runnableModel(repo, xcodebuild: "exit 0", testResults: Self.payButtonFailed,
                                          attachments: try payButtonAttachments(), failures: true, flakeResults: [earlier])
            model.scratchDirectory = AppFixtures.temporaryDirectory("scratch")
            app.show(model)
            model.section = .run
            let bundle = AppFixtures.temporaryDirectory("ci").appendingPathComponent("ci.xcresult")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

            await model.importResultBundle(bundle).value
            #expect(model.lastMessage == "Imported 1 failing test from ci.xcresult.")
            #expect(!model.lastMessageIsError)
            #expect(model.lastMessageAction == .showFailures(.lastRun))
            #expect(model.section == .lastRun)
            #expect(model.failures.map(\.id) == ["AppSnapshotTests/CheckoutViewTests/payButton()"])
            #expect(model.failingSuites.map(\.identifier) == [AppFixtures.checkoutSuite.identifier])
            #expect(model.flakeResults.isEmpty)
            let source = try #require(model.failureSource)
            #expect(source == FailureSource(label: "ci.xcresult", date: source.date, host: "imported", resultBundle: bundle))
            let failure = try #require(model.failures.first?.images.first?.failure)
            #expect(try Data(contentsOf: failure) == AppFixtures.actual)
            #expect(failure.path.hasPrefix(model.scratchDirectory.appendingPathComponent("imported").path + "/"))
            let record = try #require(model.history.last)
            #expect(record.kind == .imported)
            #expect(record.host == "ci.xcresult")
            #expect(record.failed == 1)
            #expect(record.resultBundle == bundle.path)
        }

        /// Moving snapshots to the Trash that all stay says so, without claiming any moved.
        @Test func aTrashThatMovesNothingSaysSo() throws {
            let model = AppFixtures.project(.library, store: AppFixtures.store())   // its files aren't on disk
            model.trash = Self.trash(into: AppFixtures.temporaryDirectory("Trash"))
            let file = try #require(model.displayedSnapshots.first)
            model.moveToTrash([file])
            #expect(model.lastMessageIsError)
            #expect(model.lastMessage == "Could not move payButton.dark.png to the Trash: payButton.dark.png isn’t there.")
        }

        /// Trashing the selected snapshot moves on to the next one; a trash of which only some moved
        /// says which stayed, and why.
        @Test func trashingTheSelectionSelectsTheNextOne() async throws {
            let (repo, png) = try makeRepo()
            let names = ["a", "b", "c"].map { png.replacingOccurrences(of: "card", with: $0) }
            for name in names { try AppFixtures.badged.write(to: repo.appendingPathComponent(name)) }
            let bin = AppFixtures.temporaryDirectory("Trash")
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.trash = Self.trash(into: bin)
            try await waitUntil(model.library?.files.count == 4, "the library never loaded")
            let b = try #require(model.library?.files.first { $0.path == names[1] })
            model.selectedSnapshotID = b.id

            model.moveToTrash([b])
            #expect(model.lastMessage == "Moved 1 snapshot to the Trash.")
            #expect(!model.lastMessageIsError)
            #expect(try Data(contentsOf: bin.appendingPathComponent("b.1.png")) == AppFixtures.badged)
            try await waitUntil(model.library?.files.count == 3 && !model.isLoadingLibrary, "the library never lost b.1.png")
            #expect(model.selectedSnapshotID == names[2])

            let a = try #require(model.library?.files.first { $0.path == names[0] })
            let gone = SnapshotFile(path: png.replacingOccurrences(of: "card", with: "gone"), byteSize: 0)
            model.moveToTrash([a, gone])
            #expect(model.lastMessage == "Moved 1 snapshot to the Trash. Could not move gone.1.png to the Trash: gone.1.png isn’t there.")
            #expect(model.lastMessageIsError)
        }

        /// A Trash of a test's own: moves files into `bin`, and refuses one that isn't there, as the Finder's does.
        static func trash(into bin: URL) -> (URL) throws -> Void {
            struct NotThere: LocalizedError {
                var file: String
                var errorDescription: String? { "\(file) isn’t there." }
            }
            return { url in
                guard FileManager.default.fileExists(atPath: url.path) else { throw NotThere(file: url.lastPathComponent) }
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
            }
        }

        /// Discarding a new snapshot git doesn't track yet deletes it; one that can't be deleted says
        /// why, in the system's words, and stays.
        @Test func discardingANewSnapshotDeletesIt() async throws {
            let (repo, png) = try makeRepo()
            let new = png.replacingOccurrences(of: "card", with: "new")
            let file = repo.appendingPathComponent(new)
            try AppFixtures.badged.write(to: file)
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            try await waitForChanges(model)
            let change = try #require(model.changeSet?.changes.first { $0.path == new })
            #expect(change.kind == .new)
            #expect(model.canDiscard(change))

            // Its folder read-only: the file can't be deleted. What deleting it says is the reason.
            let folder = file.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            let reason: String
            do {
                try FileManager.default.removeItem(at: file)
                Issue.record("a read-only folder let its file be deleted")
                return
            } catch {
                reason = error.localizedDescription
            }
            model.discard(change)
            #expect(model.lastMessage == "Could not discard new.1.png: \(reason)")
            #expect(model.lastMessageIsError)
            #expect(FileManager.default.fileExists(atPath: file.path))

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            model.discard(change)
            #expect(model.lastMessage == "Discarded the working-tree change to new.1.png.")
            #expect(!model.lastMessageIsError)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try Data(contentsOf: repo.appendingPathComponent(png)) == AppFixtures.actual)   // the other change stays
        }

        /// Failures selected together from two suites re-record just those tests, in both suites.
        @Test func reRecordingFailuresOfTwoSuitesRunsJustThoseTests() async throws {
            let repo = try makeRecordableRepo(suite: "CheckoutViewTests")
            let profile = "Tests/AppTests/ProfileViewTests.swift"
            try "import SnapshotTesting\nimport Testing\n\n@Suite(.snapshots(record: .missing))\nstruct ProfileViewTests {\n    @Test func badge() {}\n}\n"
                .write(to: repo.appendingPathComponent(profile), atomically: true, encoding: .utf8)
            try Shell.output(["git", "add", "--", profile], in: repo)
            try Shell.output(["git", "commit", "-qm", "suite", "--", profile], in: repo)
            let model = try runnableModel(repo, xcodebuild: "echo \"$@\" >> \"$0.args\"\nexit 0", testResults: """
                {"testNodes": [{"name": "AppSnapshotTests", "nodeType": "Unit test bundle", "children": [
                  {"name": "CheckoutViewTests", "nodeType": "Test Suite", "children": [
                    {"name": "payButton()", "nodeType": "Test Case", "nodeIdentifier": "CheckoutViewTests/payButton()", "result": "Passed"}]},
                  {"name": "ProfileViewTests", "nodeType": "Test Suite", "children": [
                    {"name": "badge()", "nodeType": "Test Case", "nodeIdentifier": "ProfileViewTests/badge()", "result": "Passed"}]}]}]}
                """, failures: true)
            model.section = .lastRun
            model.selectFailures(Set(model.displayedFailures.map(\.id)))
            #expect(model.selectedFailures.map(\.suite.name) == ["CheckoutViewTests", "ProfileViewTests"])
            model.reRecordSelection()
            #expect(model.operation == .rerecord)
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Re-recorded 2 tests. Verified: 2 passed.")
            #expect(model.failures.isEmpty)
            let xcrun = try #require(model.environment).xcode.developerDir + "/usr/bin/xcrun.args"
            let runs = try String(contentsOfFile: xcrun, encoding: .utf8).split(separator: "\n")
            #expect(runs.count == 2)                        // the record and the verification
            for run in runs {
                #expect(run.contains("-only-testing:AppSnapshotTests/CheckoutViewTests/payButton()"))
                #expect(run.contains("-only-testing:AppSnapshotTests/ProfileViewTests/badge()"))
                #expect(!run.contains("summary()"))
            }
        }

        /// A test that still fails after its re-record shows what it looks like now, as after a run.
        @Test func aFailedVerificationShowsItsImages() async throws {
            let repo = try makeRecordableRepo(suite: "CheckoutViewTests")
            let model = try runnableModel(repo, xcodebuild: Self.recordsThenFails, testResults: Self.payButtonFailed,
                                          attachments: try payButtonAttachments(), failures: true)
            let payButton = try #require(model.failures.first { $0.test.name == "payButton()" })

            model.reRecord(failures: [payButton])
            #expect(model.operation == .rerecord)
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Re-recorded payButton(). Verification still fails (1) — the test may be flaky; try Check Flakiness.")
            let images = try #require(model.failures.first { $0.id == payButton.id }?.images.first)
            #expect(images.failure.flatMap { try? Data(contentsOf: $0) } == AppFixtures.actual)
        }

        /// After a relaunch, a test whose re-record still fails shows its verification's images, and
        /// the failure the verification didn't run the full run's.
        @Test func relaunchingAfterAVerificationShowsEachFailuresImages() async throws {
            let repo = try makeRecordableRepo(suite: "CheckoutViewTests")
            let full = AppFixtures.temporaryDirectory("full")
            try FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
            for name in ["pay.png", "badge.png"] { try AppFixtures.badged.write(to: full.appendingPathComponent(name)) }
            try Data("""
                [{"testIdentifier": "CheckoutViewTests/payButton()", "attachments": [{"exportedFileName": "pay.png", "suggestedHumanReadableName": "failure_0_A.png"}]},
                 {"testIdentifier": "ProfileViewTests/badge()", "attachments": [{"exportedFileName": "badge.png", "suggestedHumanReadableName": "failure_0_B.png"}]}]
                """.utf8).write(to: full.appendingPathComponent("manifest.json"))
            LastRun(result: AppFixtures.lastResult, attachmentsDirectory: full).save(repository: repo)
            let model = try runnableModel(repo, xcodebuild: Self.recordsThenFails, testResults: Self.payButtonFailed,
                                          attachments: try payButtonAttachments(), failures: true)
            model.reRecord(failures: [try #require(model.failures.first { $0.test.name == "payButton()" })])
            #expect(model.operation == .rerecord)
            try await waitUntilFinished(model)

            let relaunched = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            for _ in 0..<200 where relaunched.failures.count != 2 { try await Task.sleep(for: .milliseconds(50)) }
            func image(_ test: String) -> Data? {
                relaunched.failures.first { $0.test.name == test }?.images.first?.failure.flatMap { try? Data(contentsOf: $0) }
            }
            #expect(image("payButton()") == AppFixtures.actual)
            #expect(image("badge()") == AppFixtures.badged)
        }

        /// Re-recorded on the remote Mac, the suites are verified there too, as `snapkit rerecord
        /// --remote` does, unless verifying is off.
        @Test func aRemoteReRecordVerifiesOnTheRemoteMac() async throws {
            let repo = try makeRecordableRepo(suite: "CheckoutViewTests")
            let snapshot = "Tests/AppTests/__Snapshots__/CheckoutViewTests/payButton.1.png"
            let mac = try FakeRemoteMac(xcodebuild: """
                if grep -q 'record: .all' Tests/AppTests/CheckoutViewTests.swift; then
                  mkdir -p "$(dirname \(snapshot))" && printf new > \(snapshot)
                  cat > "$bundle/tests.json" <<'JSON'
                \(Self.payButtonFailed)
                JSON
                  exit 65
                fi
                cat > "$bundle/tests.json" <<'JSON'
                \(Self.payButtonFailed.replacingOccurrences(of: #""result": "Failed""#, with: #""result": "Passed""#))
                JSON
                """)
            let store = AppFixtures.store()
            for verify in [true, false] {
                store.update { $0.verifyAfterRecord = verify }
                let model = remoteModel(repo, on: mac, store: store)
                model.reRecordOnRemote()
                try await waitUntilFinished(model)
                #expect(try String(contentsOf: repo.appendingPathComponent(snapshot), encoding: .utf8) == "new")
                if verify {
                    #expect(model.lastMessage == "Recorded on fake-mac; downloaded 1 snapshot. Verified: 1 passed.")
                    #expect(model.failures.isEmpty)
                    #expect(LastRun.load(repository: repo)?.failingSuites.isEmpty == true)
                } else {
                    #expect(model.lastMessage == "Recorded on fake-mac; downloaded 1 snapshot.")
                    #expect(model.failures.count == 1)
                }
                try FileManager.default.removeItem(at: repo.appendingPathComponent(snapshot))
            }
        }

        /// A model of `repo` whose remote Mac is `mac`, with payButton() failing from the last run.
        func remoteModel(_ repo: URL, on mac: FakeRemoteMac, store: ProjectStore = AppFixtures.store()) -> ProjectModel {
            let model = ProjectModel(project: Project(path: repo.path), store: store, autoload: false)
            var f = ProjectFixture()
            f.context = AppFixtures.context(at: repo, remoteHost: "fake-mac")
            f.context?.resolved.config.remoteDirectory = mac.checkout.path
            f.failingSuites = [AppFixtures.checkoutSuite]
            f.failures = AppFixtures.failures(in: AppFixtures.temporaryDirectory("failures")).filter { $0.test.name == "payButton()" }
            model.apply(f)
            model.remoteTransport = { _ in mac }
            return model
        }

        /// A run on the remote Mac shows its failures as a local run does, from that Mac, and saves
        /// them as the last run; a flakiness check there repeats just the failing tests.
        @Test func aRemoteRunAndCheckShowWhatTheMacFound() async throws {
            let (repo, _) = try makeRepo()
            let arguments = AppFixtures.temporaryDirectory("remote-args")
            let mac = try FakeRemoteMac(xcodebuild: """
                echo "$args" >> '\(arguments.path)'
                cat > "$bundle/tests.json" <<'JSON'
                \(Self.payButtonFailed)
                JSON
                exit 65
                """)
            let model = remoteModel(repo, on: mac)
            model.runRemote()
            #expect(model.operation == .remoteRun)
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "1 failing test in 1 suite")
            #expect(model.lastMessageAction == .showFailures(.lastRun))
            #expect(model.failures.map(\.id) == ["AppSnapshotTests/CheckoutViewTests/payButton()"])
            let source = try #require(model.failureSource)
            #expect(source == FailureSource(label: "Remote run", date: source.date, host: "fake-mac", resultBundle: nil))
            let last = try #require(LastRun.load(repository: repo))
            #expect((last.host, last.failed) == ("fake-mac", 1))

            model.checkFlakiness(remote: true)
            #expect(model.operation == .remoteFlakeCheck)
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "5× on fake-mac: 1 fails every time, 0 flaky, 0 pass.")
            #expect(model.failures.first?.verdict == .alwaysFails)
            let runs = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n")
            try #require(runs.count == 2)
            #expect(!runs[0].contains("-only-testing:"))                  // the run: every test
            // Just the failing test, not the passing ones in its suite.
            #expect(runs[1].split(separator: " ").filter { $0.hasPrefix("-only-testing:") }
                    == ["-only-testing:AppSnapshotTests/CheckoutViewTests/payButton()"])
            #expect(runs[1].contains("-test-iterations 5"))
        }

        /// A remote re-record whose tests don't build recorded nothing, and one cancelled says so:
        /// neither brings back a snapshot or changes the failures.
        @Test func aRemoteReRecordThatRecordsNothingSaysSo() async throws {
            let repo = try makeRecordableRepo(suite: "CheckoutViewTests")
            // Each writes a snapshot on the remote Mac first, so "brings nothing back" can fail.
            let snapshot = "Tests/AppTests/__Snapshots__/CheckoutViewTests/payButton.1.png"
            let write = #"mkdir -p "$(dirname \#(snapshot))" && printf new > \#(snapshot)"#
            let broken = try FakeRemoteMac(xcodebuild: """
                \(write)
                echo "$PWD/Tests/AppTests/CheckoutViewTests.swift:7:9: error: cannot find 'card' in scope"
                exit 65
                """)
            let model = remoteModel(repo, on: broken)
            let failures = model.failures.map(\.id)
            model.reRecordOnRemote()
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Nothing was recorded: the build failed (CheckoutViewTests.swift:7:9: cannot find 'card' in scope).")
            #expect(model.lastMessageIsError)
            #expect(model.failures.map(\.id) == failures)

            let slow = try FakeRemoteMac(xcodebuild: write + "\n" + Self.longRun)
            let cancelled = remoteModel(repo, on: slow)
            cancelled.reRecordOnRemote()
            try await waitUntilStarted(cancelled)
            cancelled.cancel()
            try await waitUntilFinished(cancelled)
            #expect(cancelled.lastMessage == "Cancelled.")
            #expect(!cancelled.lastMessageIsError)
            #expect(cancelled.failures.map(\.id) == failures)
            #expect(try Shell.output(["git", "status", "--porcelain", "--", "Tests/AppTests/__Snapshots__/CheckoutViewTests"], in: repo).isEmpty)
        }

        /// A remote re-record whose verification can't run keeps what it recorded and says why it
        /// couldn't verify; the failures stay until a run that could.
        @Test func aRemoteVerificationThatCannotRunSaysWhy() async throws {
            let repo = try makeRecordableRepo(suite: "CheckoutViewTests")
            let snapshot = "Tests/AppTests/__Snapshots__/CheckoutViewTests/payButton.1.png"
            // Records, then loses its simulators: the verification's check of the Mac fails.
            let mac = try FakeRemoteMac(xcodebuild: """
                mkdir -p "$(dirname \(snapshot))" && printf new > \(snapshot)
                cat > "$bundle/tests.json" <<'JSON'
                \(Self.payButtonFailed)
                JSON
                touch "$(dirname "$(command -v xcrun)")/no-simulators"
                exit 65
                """)
            let model = remoteModel(repo, on: mac)
            let failures = model.failures.map(\.id)
            model.reRecordOnRemote()
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Recorded on fake-mac; downloaded 1 snapshot. Could not verify: Command on fake-mac failed: No simulators.")
            #expect(model.lastMessageIsError)
            #expect(model.lastMessageAction == .reviewChanges)
            #expect(try String(contentsOf: repo.appendingPathComponent(snapshot), encoding: .utf8) == "new")
            #expect(model.failures.map(\.id) == failures)
        }
    }
}

/// A remote Mac that is a local folder, with stand-ins for its `xcodebuild` (the shell `script`, run
/// in the checkout with `$bundle` set to the result bundle and `$args` to its arguments) and `xcrun`:
/// Xcode 99.1, an Example Phone with iOS 99.0 (none once a `no-simulators` file is next to it),
/// result bundles read from their `tests.json` and without attachments.
struct FakeRemoteMac: RemoteTransport {
    let checkout: URL
    let bin: URL

    @MainActor init(xcodebuild script: String) throws {
        checkout = AppFixtures.temporaryDirectory("remote-checkout")
        bin = AppFixtures.temporaryDirectory("remote-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try install("xcodebuild", """
            args="$*"
            while [ $# -gt 0 ]; do [ "$1" = -resultBundlePath ] && bundle=$2; shift; done
            mkdir -p "$bundle"
            \(script)
            """)
        try install("xcrun", """
            if [ "$1 $2" = "simctl list" ] && [ -e "$(dirname "$0")/no-simulators" ]; then
              echo 'No simulators.' >&2; exit 70
            fi
            case "$1 $2" in
              "simctl list") echo '{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-99-0": [{"name": "Example Phone", "udid": "SIM-1", "state": "Shutdown"}]}}' ;;
              "xcresulttool get") while [ "$1" != --path ]; do shift; done; cat "$2/tests.json" ;;
              "xcresulttool export") while [ "$1" != --output-path ]; do shift; done; mkdir -p "$2" && echo '[]' > "$2/manifest.json" ;;
              *) exit 64 ;;
            esac
            """)
    }

    private func install(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    var label: String { "fake-mac" }

    func command(for script: String, interactive: Bool) -> (executable: String, arguments: [String]) {
        if script.contains("xcode-select -p") {         // the check of its Xcodes
            return ("/bin/echo", ["HOME=/Users/ci\nSELECTED=/Applications/Xcode.app/Contents/Developer\nXCODE=/Applications/Xcode.app|99.1|99A1"])
        }
        return ("/usr/bin/env", ["PATH=\(bin.path):/usr/bin:/bin", "/bin/bash", "-c", script])
    }

    func rsyncLocation(_ remotePath: String) -> String { remotePath }
    var rsyncArguments: [String] { [] }
}
