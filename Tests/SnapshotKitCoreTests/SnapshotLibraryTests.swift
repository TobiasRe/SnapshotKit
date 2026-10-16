import Foundation
import Testing
@testable import SnapshotKitCore

@Suite struct SnapshotLibraryTests {
    @Test func indexesTrackedAndNewSnapshotsWithTheirState() throws {
        let repo = try TempRepo()
        let red = png(width: 4, height: 4, rgba: (255, 0, 0, 255))
        try repo.write("Modules/Cart/Tests/CartTests/__Snapshots__/CartViewTests/total.1.png", red)
        try repo.write("Modules/Cart/Tests/CartTests/__Snapshots__/CartViewTests/row.light.png", red)
        try repo.write("Modules/Cart/Tests/CartTests/__Snapshots__/CartViewTests/row.dark.png", red)
        try repo.write("Tests/AppTests/__Snapshots__/HomeTests/header.1.png", red)
        try repo.write("Tests/AppTests/__Snapshots__/HomeTests/notes.txt", "not an image")
        try repo.write("Sources/App/logo.png", red)
        try repo.commitAll("base")
        try repo.write("Tests/AppTests/__Snapshots__/HomeTests/header.1.png", png(width: 4, height: 4, rgba: (0, 0, 255, 255)))
        try repo.write("Tests/AppTests/__Snapshots__/HomeTests/footer.1.png", red)

        let library = try SnapshotLibrary.load(repository: repo.url)
        #expect(library.files.map(\.fileName) == ["row.dark.png", "row.light.png", "total.1.png", "footer.1.png", "header.1.png"])
        #expect(library.testCount == 4)
        #expect(library.totalBytes == library.files.reduce(0) { $0 + $1.byteSize } && library.totalBytes > 0)
        let state = Dictionary(uniqueKeysWithValues: library.files.map { ($0.fileName, $0.state) })
        #expect(state["header.1.png"] == .modified)
        #expect(state["footer.1.png"] == .untracked)
        #expect(state["total.1.png"] == .clean)

        let tree = SnapshotLibrary.tree(library.files)
        #expect(tree.map(\.name) == ["AppTests", "CartTests"])
        let row = try #require(tree[1].suites.first?.tests.first { $0.name == "row" })
        #expect(row.files.map(\.variant) == ["dark", "light"])
        #expect(tree[1].fileCount == 3)
    }

    @Test func namesAndFilters() {
        let file = SnapshotFile(path: "Tests/AppTests/__Snapshots__/CardTests/card-appearance.dark.png", byteSize: 1)
        #expect(file.module == "AppTests")
        #expect(file.suite == "CardTests")
        #expect(file.testName == "card-appearance")
        #expect(file.variant == "dark")
        #expect(SnapshotLibrary.filter([file], text: "card DARK").count == 1)
        #expect(SnapshotLibrary.filter([file], text: "light").isEmpty)
    }
}

@Suite struct SnapshotHistoryTests {
    @Test func listsVersionsNewestFirstAndReadsEach() throws {
        let repo = try TempRepo()
        let path = "Tests/AppTests/__Snapshots__/CardTests/card.1.png"
        let v1 = png(width: 2, height: 2, rgba: (255, 0, 0, 255))
        let v2 = png(width: 2, height: 2, rgba: (0, 255, 0, 255))
        try repo.write(path, v1)
        try repo.commitAll("Record card")
        try repo.write("README.md", "unrelated")
        try repo.commitAll("Unrelated change")
        try repo.write(path, v2)
        try repo.commitAll("Re-record card in green")

        let versions = repo.git.history(of: path)
        #expect(versions.map(\.subject) == ["Re-record card in green", "Record card"])
        #expect(versions[0].author == "Tests")
        #expect(versions[0].shortCommit.count == 7)
        #expect(repo.git.image(of: path, at: versions[1].commit) == v1)
        #expect(repo.git.image(of: path, at: versions[0].commit) == v2)
    }

    @Test func followsRenames() throws {
        let repo = try TempRepo()
        let old = "Tests/AppTests/__Snapshots__/CardTests/card.1.png"
        let new = "Tests/AppTests/__Snapshots__/CardViewTests/card.1.png"
        let data = png(width: 2, height: 2, rgba: (0, 0, 255, 255))
        try repo.write(old, data)
        try repo.commitAll("Record")
        try repo.git.run(["mv", old.replacingOccurrences(of: "/card.1.png", with: ""), new.replacingOccurrences(of: "/card.1.png", with: "")])
        try repo.commitAll("Rename suite")

        let versions = repo.git.history(of: new)
        #expect(versions.map(\.subject) == ["Rename suite", "Record"])
        #expect(repo.git.image(of: new, at: versions[1].commit) == data)
    }
}

@Suite struct OrphanTests {
    @Test func findsSnapshotsOfRenamedAndDeletedTests() throws {
        let repo = try TempRepo()
        try repo.write("Tests/AppTests/CardTests.swift", """
            import Testing
            @Suite struct CardTests {
                @Test func compact() {}
                @Test(arguments: [1]) func sized(width: Int) {}
            }
            """)
        let red = png(width: 2, height: 2, rgba: (255, 0, 0, 255))
        let dir = "Tests/AppTests/__Snapshots__"
        for name in ["CardTests/compact.1.png", "CardTests/sized-width.1.png", "CardTests/expanded.1.png", "GoneTests/row.1.png"] {
            try repo.write("\(dir)/\(name)", red)
        }
        try repo.commitAll("base")
        let library = try SnapshotLibrary.load(repository: repo.url)
        let orphans = SnapshotLibrary.orphans(library.files, repository: repo.url)
        #expect(orphans == ["\(dir)/CardTests/expanded.1.png", "\(dir)/GoneTests/row.1.png"])
    }

    /// SnapshotKit's own snapshot tests: every reference belongs to a test.
    @Test func noFalsePositivesInThisRepository() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return }
        let library = try SnapshotLibrary.load(repository: root)
        #expect(library.files.count > 20)
        #expect(SnapshotLibrary.orphans(library.files, repository: root).isEmpty)
    }
}

@Suite struct NewReferenceTests {
    @Test func recognisesNewlyRecordedReferences() {
        let message = """
            Issue recorded: No reference was found on disk. Automatically recorded snapshot: …

            open "file:///path/to/repo/Tests/AppTests/__Snapshots__/CardTests/card.1.png"

            Re-run "card" to assert against the newly-recorded snapshot.
            """
        #expect(FailureAttachments.isNewReference(message))
        #expect(!FailureAttachments.isNewReference("Snapshot does not match reference."))
        #expect(FailureAttachments.referencePaths(in: message, repository: URL(fileURLWithPath: "/path/to/repo"))
                == ["Tests/AppTests/__Snapshots__/CardTests/card.1.png"])
    }
}
