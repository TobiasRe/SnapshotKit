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
        init() {
            AppFixtures.resetDefaults()
            // The tests' git and the app's must not pick up hooks, templates or settings of this machine's user.
            setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
            setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
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
            let next = try #require(model.filteredChanges.last)
            #expect(model.selectedChangeID == next.id)

            // A fresh model reads the marks back.
            let reopened = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            reopened.updateSettings { $0.baseBranch = "develop" }
            await waitForChanges(reopened)
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
            await waitForChanges(model)
            for _ in 0..<500 where model.invisibleUncommitted.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.invisibleUncommitted.map(\.fileName) == ["noisy.1.png"])

            model.discardInvisibleChanges()
            for _ in 0..<500 where model.lastMessage == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(try Data(contentsOf: repo.appendingPathComponent(noisy)) == AppFixtures.reference)
            #expect(try Data(contentsOf: repo.appendingPathComponent(png)) == AppFixtures.actual)
            #expect(model.lastMessage?.hasPrefix("Discarded 1 re-recorded snapshot") == true)
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

        /// An orphan's test is gone, whichever tab it is selected on.
        @Test func anOrphanedChangeCannotBeReRecorded() throws {
            let model = ProjectModel(project: Project(path: AppFixtures.repository.path), store: AppFixtures.store(), autoload: false)
            let orphan = try #require(AppFixtures.libraryImages.first { $0.0.testName == "oldAvatar" }).0
            var f = ProjectFixture()
            f.context = AppFixtures.context
            f.environment = AppFixtures.environment
            f.tab = .changes
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
            let root = AppFixtures.temporaryDirectory("scan")
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
            #expect(ids("work").allSatisfy { $0.hasPrefix("project:") })   // path matches still find projects
        }

        @Test func paletteOffersOnlyWhatCanBeDoneNow() {
            let app = AppModel(store: AppFixtures.store())
            #expect(PaletteCommand.available(app: app).map(\.title) == ["Add Project…"])   // no project open
            let model = AppFixtures.project(.failedRun, store: app.store)
            app.show(model)
            let titles = PaletteCommand.available(app: app).map(\.title)
            #expect(titles.contains("Re-record Failing Suites"))
            #expect(!titles.contains("Cancel Run"))
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

        @Test func showInLibraryClearsFiltersThatHideTheSnapshot() throws {
            let model = AppFixtures.project(.library, store: AppFixtures.store())
            let header = try #require(AppFixtures.libraryImages.first { $0.0.testName == "header" }).0
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
            let file = AppFixtures.temporaryDirectory("loose").appendingPathExtension("txt")
            try Data("x".utf8).write(to: file)
            #expect(!app.addDroppedFolders([file]))
        }

        /// A folder that is gone (or never was a repository) is not added as a project, and the window says why.
        @Test func openingAFolderOutsideAnyRepositoryIsRefused() throws {
            let app = AppModel(store: AppFixtures.store())
            let projects = app.projects.map(\.path)
            let missing = AppFixtures.temporaryDirectory("gone").appendingPathComponent("Shop")
            #expect(app.open(path: missing.path) == nil)
            #expect(app.startupNotice?.contains("Shop") == true)
            let plain = AppFixtures.temporaryDirectory("plain")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            #expect(app.open(path: plain.path) == nil)
            #expect(app.projects.map(\.path) == projects)
            #expect(app.current == nil)
            #expect(app.store.settings.recents.allSatisfy { $0 != missing.path && $0 != plain.path })
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
            model.updateSettings { $0.baseBranch = "release/1.0" }
            await waitForChanges(model)
            let changes = try #require(model.changeSet?.changes)
            #expect(changes.count == 3)
            let base = [png: AppFixtures.reference, second: AppFixtures.badged, other: AppFixtures.renderingNoise]
            var urls: Set<URL> = []
            for change in changes {
                let url = try #require(model.exportBaseImage(for: change))
                urls.insert(url)
                #expect(try Data(contentsOf: url) == base[change.path])
            }
            #expect(urls.count == 3)
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
            // An Xcode whose simctl takes a second to fail.
            let slow = AppFixtures.temporaryDirectory("slow").appendingPathComponent("Xcode.app")
            let xcrun = slow.appendingPathComponent("Contents/Developer/usr/bin/xcrun")
            try FileManager.default.createDirectory(at: xcrun.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\nsleep 1\nexit 1\n".write(to: xcrun, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "99.1"], format: .xml, options: 0)
                .write(to: slow.appendingPathComponent("Contents/version.plist"))
            let override = repo.appendingPathComponent(".snapshotkit.yml")

            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store(), autoload: false)
            try "developerDir: \(slow.path)\n".write(to: override, atomically: true, encoding: .utf8)
            model.reload()
            for _ in 0..<200 where model.config?.developerDir != slow.path { try await Task.sleep(for: .milliseconds(20)) }
            try "developerDir: /nonexistent/Xcode.app\n".write(to: override, atomically: true, encoding: .utf8)
            model.reload()
            for _ in 0..<200 where model.environmentError == nil { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .seconds(1.5))       // the first check is done by now
            #expect(model.environmentError?.contains("/nonexistent/Xcode.app does not exist") == true)
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
            await waitForChanges(model)
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

        /// Discarding the selected change moves on to the next one, as a review goes, not back to the top.
        @Test func discardingTheSelectionSelectsTheNextOne() async throws {
            let (repo, png) = try makeRepo()
            let names = ["a", "b", "c"].map { png.replacingOccurrences(of: "card", with: $0) }
            for name in names { try AppFixtures.badged.write(to: repo.appendingPathComponent(name)) }
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            await waitForChanges(model)
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

        /// ⌥⌘↓ and a jump from the Run tab focus one failure, even inside a multi-selection.
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
            model.tab = .snapshots
            model.showChange(path: viewed.path)
            #expect(model.tab == .changes)
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
            model.libraryScope = .failing                   // only badge fails
            #expect(model.selectedSnapshot?.testName == "badge")
            model.libraryScope = .all
            #expect(model.selectedSnapshot?.testName == "badge")
            model.libraryFilter = "nothing like this"
            #expect(model.selectedSnapshot?.testName == "badge")
            model.selectAdjacent(1)                         // nothing to move to
            #expect(model.selectedSnapshot?.testName == "badge")

            let changes = AppFixtures.project(.changes, store: AppFixtures.store())
            changes.tab = .changes
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

        /// A run that fixes the selected snapshot's test takes it out of the Failing scope: the selection
        /// moves to the first snapshot shown, as when a filter hides it.
        @Test func aRunThatFixesTheSelectionMovesIt() async throws {
            let (repo, _) = try makeRepo()
            let dark = "\(AppFixtures.snapshotDir)/CheckoutViewTests/payButton.dark.png"
            let message = #"Snapshot does not match reference.\n\n@\u2212\n\"file://\#(repo.path)/\#(dark)\"\n@+\n\"file:///tmp/payButton.dark.png\""#
            let model = try runnableModel(repo, xcodebuild: "exit 65", testResults: """
                {"testNodes": [{"name": "AppSnapshotTests", "nodeType": "Unit test bundle", "children": [
                  {"name": "CheckoutViewTests", "nodeType": "Test Suite", "children": [
                    {"name": "payButton()", "nodeType": "Test Case", "nodeIdentifier": "CheckoutViewTests/payButton()", "result": "Failed",
                     "children": [{"name": "\(message)", "nodeType": "Failure Message", "result": "Failed"}]}]},
                  {"name": "ProfileViewTests", "nodeType": "Test Suite", "children": [
                    {"name": "badge()", "nodeType": "Test Case", "nodeIdentifier": "ProfileViewTests/badge()", "result": "Passed"}]}]}]}
                """, failures: true, library: true)
            model.libraryScope = .failing
            #expect(model.selectedSnapshot?.testName == "badge")
            model.runTests()
            try await waitUntilFinished(model)
            #expect(model.failures.map(\.test.name) == ["payButton()"])
            #expect(model.selectedSnapshotID == dark)
        }

        /// Reverting the selected snapshot takes it out of the Changed scope: the selection moves on.
        @Test func revertingTheSelectionInTheChangedScopeMovesIt() async throws {
            let (repo, png) = try makeRepo()
            let other = png.replacingOccurrences(of: "card", with: "other")
            try AppFixtures.badged.write(to: repo.appendingPathComponent(other))
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            await waitForChanges(model)
            for _ in 0..<200 where model.library?.files.count != 2 { try await Task.sleep(for: .milliseconds(50)) }
            model.libraryScope = .changed
            model.selectedSnapshotID = png
            model.revertToBase([try #require(model.changeSet?.changes.first { $0.path == png })])
            for _ in 0..<200 where model.changeSet?.changes.count != 1 || model.isLoadingLibrary { try await Task.sleep(for: .milliseconds(50)) }
            #expect(model.displayedSnapshots.map(\.id) == [other])
            #expect(model.selectedSnapshotID == other)
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

        /// Switching what to compare with twice in a row shows the second, whichever git finishes first.
        @Test func theLatestRefreshWins() async throws {
            let (repo, _) = try makeRepo()
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            await waitForChanges(model)
            for _ in 0..<10 {
                model.diffBase = .tip
                model.diffBase = .mergeBase
                for _ in 0..<200 where model.isLoadingChanges { try await Task.sleep(for: .milliseconds(20)) }
                #expect(model.changeSet?.diffBase == .mergeBase)
            }
        }

        /// A branch checked out outside the app shows once the changes refresh (as on coming back to the app).
        @Test func aBranchCheckedOutElsewhereShowsOnRefresh() async throws {
            let (repo, _) = try makeRepo()
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            model.updateSettings { $0.baseBranch = "develop" }
            await waitForChanges(model)
            #expect(model.currentBranch == "feature")
            try Shell.output(["git", "checkout", "-q", "-b", "release"], in: repo)
            model.refreshChanges()
            for _ in 0..<200 where model.currentBranch != "release" { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.currentBranch == "release")
            #expect(model.branches.contains("release"))
        }

        /// A repository deleted while open says so when checked again, instead of looking ready to run.
        @Test func aDeletedRepositorySaysSo() async throws {
            let (repo, _) = try makeRepo()
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            for _ in 0..<200 where model.context == nil { try await Task.sleep(for: .milliseconds(20)) }
            try FileManager.default.removeItem(at: repo)
            model.reload()
            for _ in 0..<200 where model.configError == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.context == nil)
            #expect(model.configError?.contains("no folder") == true)
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

            model.setBaseBranch("develop")
            await waitForChanges(model)
            #expect(model.failures.map(\.id) == failures)
            #expect(model.failureSource?.host == "imported")
        }

        /// A project added while the counts are being read gets its count too.
        @Test func failingCountsCoverAProjectAddedWhileCounting() async throws {
            let solid = DS.solidSurfaces
            DS.solidSurfaces = false        // snapshot tests leave the counts out
            defer { DS.solidSurfaces = solid }
            let (repo, _) = try makeRepo()
            saveLastRun(in: repo, suites: [], failed: 2)
            let app = AppModel(store: AppFixtures.store())     // starts counting the projects it knows
            app.open(path: repo.path)
            for _ in 0..<200 where app.failingCounts[repo.path] == nil { try await Task.sleep(for: .milliseconds(50)) }
            #expect(app.failingCounts[repo.path] == 2)
        }

        // MARK: Operations

        /// A model of `repo` that can run, with `script` as xcodebuild.
        func runnableModel(_ repo: URL, xcodebuild script: String, testResults: String? = nil, attachments: URL? = nil,
                           failures: Bool = false, flakeResults: [FlakeResult] = [], library: Bool = false) throws -> ProjectModel {
            let model = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store(), autoload: false)
            var f = ProjectFixture()
            f.context = AppFixtures.context(at: repo)
            f.environment = try AppFixtures.fakeXcode(script, testResults: testResults, attachments: attachments)
            f.tab = .failures
            if failures {
                f.lastResult = AppFixtures.lastResult
                f.failingSuites = [AppFixtures.checkoutSuite, AppFixtures.profileSuite]
                f.failures = AppFixtures.failures(in: AppFixtures.temporaryDirectory("failures"))
            }
            f.flakeResults = flakeResults
            if library { f.library = SnapshotLibrary(files: AppFixtures.libraryImages.map(\.0)) }
            model.apply(f)
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

        /// While one operation runs, another is refused; the first one carries on.
        @Test func aSecondOperationWaitsForTheFirst() async throws {
            let (repo, _) = try makeRepo()
            let model = try runnableModel(repo, xcodebuild: Self.longRun, failures: true)
            model.runTests()
            try await waitUntilStarted(model)
            model.reRecordFailed()
            model.checkFlakiness()
            #expect(model.operation == .run)
            #expect(model.stageLabel == RunOperation.run.label)
            model.cancel()
            try await waitUntilFinished(model)
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
            let model = try runnableModel(repo, xcodebuild: Self.longRun, failures: true)
            let failures = model.failures.map(\.id)
            model.runTests()
            try await waitUntilStarted(model)
            model.cancel()
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Cancelled.")
            #expect(model.failures.map(\.id) == failures)
            #expect(model.failingSuites.count == 2)
            #expect(LastRun.load(repository: repo) == nil)
        }

        /// A re-record's progress is not measured against the last full run's test count.
        @Test func reRecordingForgetsTheLastRunsTotal() async throws {
            let (repo, _) = try makeRepo()
            let model = try runnableModel(repo, xcodebuild: Self.longRun, failures: true)
            model.runTests()                    // expects as many tests as the last run had
            #expect(model.expectedTotal == 3)
            model.cancel()
            try await waitUntilFinished(model)
            model.reRecordFailed()
            #expect(model.isRunning)
            #expect(model.expectedTotal == nil)
            model.cancel()
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
            let model = try runnableModel(repo, xcodebuild: Self.longRun)
            model.reRecordFailed(suites: [Self.cardSuite])
            try await waitUntilStarted(model)
            model.cancel()
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Cancelled.")
            #expect(try Shell.output(["git", "status", "--porcelain", "--", "Tests/AppTests/CardTests.swift"], in: repo).isEmpty)
        }

        /// Cancelling the verification after a re-record leaves the failures as they were.
        @Test func cancellingTheVerificationKeepsTheFailures() async throws {
            let repo = try makeRecordableRepo()
            // Records at once; the second run, the verification, waits.
            let model = try runnableModel(repo, xcodebuild: "[ -e \"$0.ran\" ] || { touch \"$0.ran\"; exit 0; }\n" + Self.longRun,
                                          testResults: Self.cardPassed, failures: true)
            let failures = model.failures.map(\.id)
            model.reRecordFailed(suites: [Self.cardSuite])
            try await waitUntilStarted(model)
            model.cancel()
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Re-recorded CardTests.")
            #expect(model.failures.map(\.id) == failures)
            #expect(LastRun.load(repository: repo) == nil)
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
            #expect(model.lastMessage?.hasPrefix("Nothing was recorded: the build failed") == true)
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
            for _ in 0..<200 where !model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
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
            model.tab = .run
            model.checkFlakiness()
            try await waitUntilFinished(model)
            #expect(model.tab == .failures)

            model.tab = .run
            model.checkFlakiness()
            model.tab = .changes                            // moved to another tab meanwhile
            try await waitUntilFinished(model)
            #expect(model.tab == .changes)
            #expect(model.lastMessageAction == .showFailures)

            model.tab = .run
            model.checkFlakiness()
            app.show(AppFixtures.project(.library, store: app.store))   // and to another project
            try await waitUntilFinished(model)
            #expect(model.tab == .run)
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
            for _ in 0..<100 where app.projectModel(path: model.project.path) != nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(app.projectModel(path: model.project.path) == nil)
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

        /// A flakiness check's summary reads right for one test.
        @Test func aFlakinessCheckOfOneTestReadsRight() async throws {
            let (repo, _) = try makeRepo()
            let model = try runnableModel(repo, xcodebuild: "exit 65", testResults: Self.payButtonFailed, failures: true)
            model.checkFlakiness(tests: [AppFixtures.checkoutSuite.identifier + "/payButton()"])
            try await waitUntilFinished(model)
            #expect(model.lastMessage?.hasSuffix(": 1 fails every time, 0 flaky, 0 pass.") == true)
        }

        /// Checking one test again says what that check found, not what earlier checks of other tests did.
        @Test func aFlakinessCheckCountsOnlyTheTestsItChecked() async throws {
            let (repo, _) = try makeRepo()
            let earlier = FlakeResult(suite: AppFixtures.profileSuite.identifier, test: "badge()", passed: 5, failed: 0, verdict: .passes)
            let model = try runnableModel(repo, xcodebuild: "exit 65", testResults: Self.payButtonFailed, failures: true,
                                          flakeResults: [earlier])
            model.checkFlakiness(tests: [AppFixtures.checkoutSuite.identifier + "/payButton()"])
            try await waitUntilFinished(model)
            #expect(model.lastMessage?.hasSuffix(": 1 fails every time, 0 flaky, 0 pass.") == true)
            #expect((model.passed, model.failed) == (0, 1))
            // The earlier verdict stays.
            #expect(model.flakeResults.map(\.id).contains(earlier.id))
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
            let model = try runnableModel(repo, xcodebuild: """
                [ -e "$0.ran" ] || { touch "$0.ran"; exit 0; }
                for arg; do [ "$p" = -resultBundlePath ] && rm -rf "$arg"; p=$arg; done
                exit 65
                """, testResults: Self.cardPassed, failures: true)
            let failures = model.failures.map(\.id)
            model.reRecordFailed(suites: [Self.cardSuite])
            for _ in 0..<200 where !model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
            try await waitUntilFinished(model)
            #expect(model.lastMessage == "Re-recorded CardTests. Could not verify: no test ran.")
            #expect(model.lastMessageIsError)
            #expect(model.failures.map(\.id) == failures)
            #expect(LastRun.load(repository: repo) == nil)
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
            let model = AppFixtures.project(.failures, store: AppFixtures.store())
            let failures = model.failures.map(\.id)
            await model.importResultBundle(AppFixtures.temporaryDirectory("missing").appendingPathExtension("xcresult")).value
            #expect(model.lastMessageIsError)
            #expect(model.lastMessage?.hasPrefix("Could not read missing-") == true)
            #expect(model.failures.map(\.id) == failures)
        }

        /// Moving snapshots to the Trash that all stay says so, without claiming any moved.
        @Test func aTrashThatMovesNothingSaysSo() throws {
            let model = AppFixtures.project(.library, store: AppFixtures.store())   // its files aren't on disk
            let file = try #require(model.displayedSnapshots.first)
            model.moveToTrash([file])
            #expect(model.lastMessageIsError)
            #expect(model.lastMessage?.hasPrefix("Could not move \(file.fileName) to the Trash") == true)
        }

        /// Failures selected together from two suites re-record just those tests, in both suites.
        @Test func reRecordingFailuresOfTwoSuitesRunsJustThoseTests() async throws {
            let repo = try makeRecordableRepo(suite: "CheckoutViewTests")
            let profile = "Tests/AppTests/ProfileViewTests.swift"
            try "import SnapshotTesting\nimport Testing\n\n@Suite(.snapshots(record: .missing))\nstruct ProfileViewTests {\n    @Test func badge() {}\n}\n"
                .write(to: repo.appendingPathComponent(profile), atomically: true, encoding: .utf8)
            try Shell.output(["git", "add", "--", profile], in: repo)
            try Shell.output(["git", "commit", "-qm", "suite", "--", profile], in: repo)
            let model = try runnableModel(repo, xcodebuild: "echo \"$@\" >> \"$0.args\"\nexit 0", testResults: Self.payButtonFailed, failures: true)
            model.tab = .failures
            model.selectFailures(Set(model.displayedFailures.map(\.id)))
            #expect(model.selectedFailures.map(\.suite.name) == ["CheckoutViewTests", "ProfileViewTests"])
            model.reRecordSelection()
            for _ in 0..<200 where !model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
            try await waitUntilFinished(model)
            #expect(model.lastMessage?.hasPrefix("Re-recorded 2 tests.") == true)
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
            for _ in 0..<200 where !model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
            try await waitUntilFinished(model)
            #expect(model.lastMessage?.contains("Verification still fails") == true)
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
            for _ in 0..<200 where !model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
            try await waitUntilFinished(model)

            let relaunched = ProjectModel(project: Project(path: repo.path), store: AppFixtures.store())
            for _ in 0..<200 where relaunched.failures.count != 2 { try await Task.sleep(for: .milliseconds(50)) }
            func image(_ test: String) -> Data? {
                relaunched.failures.first { $0.test.name == test }?.images.first?.failure.flatMap { try? Data(contentsOf: $0) }
            }
            #expect(image("payButton()") == AppFixtures.actual)
            #expect(image("badge()") == AppFixtures.badged)
        }
    }
}
