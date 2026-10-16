import AppKit
import Foundation
import SnapshotKitCore
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

        func waitForChanges(_ model: ProjectModel) async {
            for _ in 0..<50 where model.isLoadingChanges || model.changeSet == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
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
            for _ in 0..<100 where model.invisibleUncommitted.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.invisibleUncommitted.map(\.fileName) == ["noisy.1.png"])

            model.discardInvisibleChanges()
            for _ in 0..<100 where model.lastMessage == nil { try await Task.sleep(for: .milliseconds(20)) }
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
            #expect(!app.addDroppedFolders([FileManager.default.temporaryDirectory]))
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
            for _ in 0..<100 where model.context == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.context?.repository.path == repo.path)
            #expect(model.currentBranch == "feature")
            #expect(model.branches.prefix(1) == ["develop"])
        }
    }
}
