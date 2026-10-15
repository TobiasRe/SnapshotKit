import AppKit
import Foundation
import SnapshotKitCore
import Testing
@testable import SnapshotKit

@MainActor
@Suite(.serialized)
struct ProjectModelTests {
    /// A repo on `feature` with one committed snapshot change and one uncommitted re-record.
    func makeRepo() throws -> (URL, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-model-\(UUID().uuidString)").resolvingSymlinksInPath()
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
