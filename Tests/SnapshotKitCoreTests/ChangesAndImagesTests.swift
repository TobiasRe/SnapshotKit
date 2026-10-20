import CoreGraphics
import Foundation
import Testing
@testable import SnapshotKitCore

@Suite struct SnapshotChangesTests {
    let red = png(width: 4, height: 4, rgba: (255, 0, 0, 255))
    let blue = png(width: 4, height: 4, rgba: (0, 0, 255, 255))

    @Test func classifiesCommittedUncommittedNewAndDeleted() throws {
        let repo = try TempRepo()
        let snaps = "Tests/AppTests/__Snapshots__"
        try repo.write("\(snaps)/CardTests/committed.1.png", red)
        try repo.write("\(snaps)/CardTests/uncommitted.1.png", red)
        try repo.write("\(snaps)/ListTests/deleted.1.png", red)
        try repo.write("\(snaps)/ListTests/same.1.png", red)
        try repo.commitAll("base")

        try repo.git.run(["checkout", "-q", "-b", "feature"])
        try repo.write("\(snaps)/CardTests/committed.1.png", blue)
        try repo.write("\(snaps)/ListTests/added.1.png", blue)
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("\(snaps)/ListTests/deleted.1.png"))
        try repo.commitAll("feature work")
        // Changes on develop after branching must not show up.
        try repo.git.run(["checkout", "-q", "develop"])
        try repo.write("\(snaps)/ListTests/same.1.png", blue)
        try repo.commitAll("develop moved")
        try repo.git.run(["checkout", "-q", "feature"])
        try repo.write("\(snaps)/CardTests/uncommitted.1.png", blue)
        try repo.write("\(snaps)/ListTests/untracked.1.png", blue)

        let set = try repo.git.snapshotChanges(baseBranch: "develop")
        let kinds = Dictionary(uniqueKeysWithValues: set.changes.map { ($0.fileName, $0.kind) })
        #expect(kinds == [
            "committed.1.png": .committed,
            "uncommitted.1.png": .uncommitted,
            "added.1.png": .new,
            "untracked.1.png": .new,
            "deleted.1.png": .deleted,
        ])
        // Only the file git doesn't track yet can be discarded by deleting it.
        #expect(set.changes.filter(\.isUntracked).map(\.fileName) == ["untracked.1.png"])
        #expect(set.groups.map(\.suite) == ["CardTests", "ListTests"])
        #expect(repo.git.baseImage(for: try #require(set.changes.first { $0.fileName == "committed.1.png" }), in: set) == red)
        #expect(repo.git.currentImage(for: try #require(set.changes.first { $0.fileName == "deleted.1.png" })) == nil)

        // Against the tip, develop's own change appears too.
        let tip = try repo.git.snapshotChanges(baseBranch: "develop", against: .tip)
        #expect(tip.changes.contains { $0.fileName == "same.1.png" })
    }

    @Test func revertingPutsEveryKindBackTheWayTheBaseHasIt() throws {
        let repo = try TempRepo()
        let snaps = "Tests/AppTests/__Snapshots__"
        try repo.write("\(snaps)/CardTests/committed.1.png", red)
        try repo.write("\(snaps)/CardTests/uncommitted.1.png", red)
        try repo.write("\(snaps)/ListTests/deleted.1.png", red)
        try repo.commitAll("base")
        try repo.git.run(["checkout", "-q", "-b", "feature"])
        try repo.write("\(snaps)/CardTests/committed.1.png", blue)
        try repo.write("\(snaps)/ListTests/added.1.png", blue)
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("\(snaps)/ListTests/deleted.1.png"))
        try repo.commitAll("feature work")
        try repo.write("\(snaps)/CardTests/uncommitted.1.png", blue)
        try repo.write("\(snaps)/ListTests/untracked.1.png", blue)

        let set = try repo.git.snapshotChanges(baseBranch: "develop")
        #expect(set.changes.count == 5)
        // One first, so the others stay untouched.
        try repo.git.revertToBase(set.changes.filter { $0.fileName == "committed.1.png" }, in: set)
        #expect(try repo.git.snapshotChanges(baseBranch: "develop").changes.map(\.fileName).sorted()
                == ["added.1.png", "deleted.1.png", "uncommitted.1.png", "untracked.1.png"])
        #expect(FileManager.default.contents(atPath: repo.url.appendingPathComponent("\(snaps)/CardTests/committed.1.png").path) == red)

        try repo.git.revertToBase(set.changes, in: set)
        let left = try repo.git.snapshotChanges(baseBranch: "develop").changes
        #expect(left.isEmpty, "\(left)")
        #expect(FileManager.default.contents(atPath: repo.url.appendingPathComponent("\(snaps)/ListTests/deleted.1.png").path) == red)
        #expect(!FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("\(snaps)/ListTests/added.1.png").path))
        // Nothing staged: the revert is there to review and commit.
        #expect(try repo.git.run(["diff", "--cached", "--name-only"]).isEmpty)

        // The restored file is untracked on this branch; drawn differently, it is a change again.
        try repo.write("\(snaps)/ListTests/deleted.1.png", blue)
        #expect(try repo.git.snapshotChanges(baseBranch: "develop").changes.map(\.kind) == [.uncommitted])
    }

    /// Re-recording a snapshot that is already changed keeps its path and kind; only the stamp tells the
    /// new picture from the old one, so the app doesn't show cached images of the old.
    @Test func reRecordingAChangedSnapshotChangesItsStamp() throws {
        let repo = try TempRepo()
        let snaps = "Tests/AppTests/__Snapshots__"
        try repo.write("\(snaps)/CardTests/card.1.png", red)
        try repo.write("\(snaps)/CardTests/gone.1.png", red)
        try repo.commitAll("base")
        try repo.git.run(["checkout", "-q", "-b", "feature"])
        try repo.write("\(snaps)/CardTests/card.1.png", blue)
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("\(snaps)/CardTests/gone.1.png"))
        let before = try #require(try repo.git.snapshotChanges(baseBranch: "develop").changes.first { $0.fileName == "card.1.png" })

        let green = png(width: 4, height: 4, rgba: (0, 255, 0, 255))
        let url = repo.url.appendingPathComponent("\(snaps)/CardTests/card.1.png")
        try green.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        let set = try repo.git.snapshotChanges(baseBranch: "develop")
        let after = try #require(set.changes.first { $0.fileName == "card.1.png" })

        #expect((after.path, after.kind) == (before.path, before.kind))
        #expect(before.contentStamp != nil && after.contentStamp != before.contentStamp)
        #expect(set.changes.first { $0.fileName == "gone.1.png" }?.contentStamp == nil)   // nothing on disk
    }

    @Test func nonASCIINamesAreClassified() throws {
        let repo = try TempRepo()
        let snaps = "Tests/AppTests/__Snapshots__/ÜbersichtTests"
        try repo.write("\(snaps)/größe.1.png", red)
        try repo.write("\(snaps)/gelöscht.1.png", red)
        try repo.commitAll("base")
        try repo.git.run(["checkout", "-q", "-b", "feature"])
        try repo.write("\(snaps)/größe.1.png", blue)
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("\(snaps)/gelöscht.1.png"))
        try repo.write("\(snaps)/neu é.1.png", blue)

        let kinds = Dictionary(uniqueKeysWithValues: try repo.git.snapshotChanges(baseBranch: "develop").changes.map { ($0.fileName, $0.kind) })
        #expect(kinds == ["größe.1.png": .uncommitted, "gelöscht.1.png": .deleted, "neu é.1.png": .new])
    }

    /// On a case-insensitive file system (the macOS default) the old name still "exists" on disk.
    @Test func caseOnlyRenameIsADeletionAndANewFileAndRevertsToTheOldName() throws {
        let repo = try TempRepo()
        let snaps = "Tests/AppTests/__Snapshots__/CardTests"
        try repo.write("\(snaps)/card.1.png", red)
        try repo.commitAll("base")
        try repo.git.run(["checkout", "-q", "-b", "feature"])
        try repo.git.run(["mv", "\(snaps)/card.1.png", "\(snaps)/Card.1.png"])
        try repo.commitAll("rename")

        let set = try repo.git.snapshotChanges(baseBranch: "develop")
        let kinds = Dictionary(uniqueKeysWithValues: set.changes.map { ($0.fileName, $0.kind) })
        #expect(kinds == ["card.1.png": .deleted, "Card.1.png": .new])

        try repo.git.revertToBase(set.changes, in: set)
        let names = try FileManager.default.contentsOfDirectory(atPath: repo.url.appendingPathComponent(snaps).path)
        #expect(names == ["card.1.png"])
        #expect(FileManager.default.contents(atPath: repo.url.appendingPathComponent("\(snaps)/card.1.png").path) == red)
    }

    /// The same PNGs as the library: an app icon or a test fixture is not a snapshot.
    @Test func onlyImagesUnderSnapshotsFoldersAreChanges() throws {
        let repo = try TempRepo()
        try repo.write("App/Assets.xcassets/AppIcon.appiconset/icon.png", red)
        try repo.write("Tests/AppTests/__Snapshots__/CardTests/card.1.png", red)
        try repo.commitAll("base")
        try repo.git.run(["checkout", "-q", "-b", "feature"])
        try repo.write("App/Assets.xcassets/AppIcon.appiconset/icon.png", blue)
        try repo.write("Tests/AppTests/Fixtures/photo.png", blue)
        try repo.write("Tests/AppTests/__Snapshots__/CardTests/card.1.png", blue)

        let changes = try repo.git.snapshotChanges(baseBranch: "develop").changes
        #expect(changes.map(\.path) == ["Tests/AppTests/__Snapshots__/CardTests/card.1.png"])
    }

    /// The library's order: numbers by value, so `width.25` comes before `width.100`.
    @Test func changesAreInTheLibrarysNaturalOrder() throws {
        let repo = try TempRepo()
        try repo.write("README.md", "x")
        try repo.commitAll("base")
        let names = ["width.0.png", "width.100.png", "width.25.png", "Width.60.png"]
        for name in names { try repo.write("Tests/AppTests/__Snapshots__/CardTests/\(name)", red) }

        let set = try repo.git.snapshotChanges(baseBranch: "develop")
        let ordered = ["width.0.png", "width.25.png", "Width.60.png", "width.100.png"]
        #expect(set.changes.map(\.fileName) == ordered)
        #expect(set.groups.first?.changes.map(\.fileName) == ordered)
        #expect(SnapshotLibrary(files: set.changes.map { SnapshotFile(path: $0.path, byteSize: 0) }).files.map(\.fileName) == ordered)
    }

    @Test func filterAndNames() {
        let changes = [
            SnapshotChange(path: "T/__Snapshots__/CardTests/darkMode.1.png", kind: .committed),
            SnapshotChange(path: "T/__Snapshots__/ListTests/empty.2.png", kind: .new),
        ]
        #expect(SnapshotChangeSet.filter(changes, text: "card dark").map(\.testName) == ["darkMode"])
        // A named snapshot's test is the part before the name, as in the library.
        let named = SnapshotChange(path: "T/__Snapshots__/CardTests/payButton.dark.png", kind: .new)
        #expect(named.testName == "payButton")
        #expect(named.testName == SnapshotFile(path: named.path, byteSize: 0).testName)
        #expect(SnapshotChangeSet.filter(changes, text: "", kinds: [.new]).map(\.suite) == ["ListTests"])
    }

    @Test func baseRefPrefersTheRemoteTrackingBranch() throws {
        let repo = try TempRepo()
        try repo.write("a", "a")
        try repo.commitAll("init")
        #expect(repo.git.resolveBaseRef("develop") == "develop")
        #expect(repo.git.resolveBaseRef("nope") == nil)
        try repo.git.run(["update-ref", "refs/remotes/origin/develop", "HEAD"])
        #expect(repo.git.resolveBaseRef("develop") == "origin/develop")
    }

    /// Messages read like the app around them: “names” and apostrophes are typographic, and only
    /// code to type (in backticks) keeps straight quotes.
    @Test func messagesUseTypographicQuotes() {
        let errors: [any LocalizedError] = [
            SnapshotChangeError.baseBranchNotFound("develop"), SnapshotChangeError.noCommits,
            SnapshotChangeError.noMergeBase("origin/develop", shallow: true), SnapshotChangeError.noMergeBase("origin/develop", shallow: false),
            RecordPatchError.declarationNotFound(suite: "CardTests", file: "CardTests.swift"),
            RecordPatchError.xctestAlreadyOverridesInvokeTest(suite: "CardTests", file: "CardTests.swift"),
            RecordPatchError.suiteFileNotFound("CardTests"),
            EnvironmentError.simulatorMissing(name: "iPhone 16", platform: "iOS", os: "18.2", available: []),
            RemoteError.notConfigured, RemoteError.invalidHost("-x"), RemoteError.unsafeRemotePath(host: "ci", path: "/a b"),
        ]
        for error in errors {
            let prose = (error.errorDescription ?? "").replacingOccurrences(of: "`[^`]*`", with: "", options: .regularExpression)
            #expect(!prose.contains("'") && !prose.contains("\""), "\(prose)")
        }
        #expect(SnapshotChangeError.baseBranchNotFound("develop").errorDescription?.hasPrefix("Base branch “develop” was not found") == true)
    }

    /// CI checks out with `--depth 1`: the base branch is there, where this branch left it isn't.
    @Test func aShallowCloneWithoutTheMergeBaseSaysHowToGetIt() throws {
        let origin = try TempRepo()
        try origin.write("Tests/AppTests/__Snapshots__/CardTests/card.1.png", red)
        try origin.commitAll("base")
        try origin.git.run(["checkout", "-q", "-b", "feature"])
        try origin.write("Tests/AppTests/__Snapshots__/CardTests/card.1.png", blue)
        try origin.commitAll("feature")
        let clone = testTemp("shallow")
        try Shell.output(["git", "clone", "-q", "--depth", "1", "--no-single-branch", "--branch", "feature", "file://" + origin.url.path, clone.path])
        let git = Git(root: clone)

        #expect(throws: SnapshotChangeError.noMergeBase("origin/develop", shallow: true)) { try git.snapshotChanges(baseBranch: "develop") }
        #expect(SnapshotChangeError.noMergeBase("origin/develop", shallow: true).errorDescription?.contains("git fetch --unshallow") == true)
        #expect(try git.snapshotChanges(baseBranch: "develop", against: .tip).changes.count == 1)
    }

    @Test func aRepositoryWithoutCommitsHasNothingToCompare() throws {
        let repo = try TempRepo()
        try repo.write("Tests/AppTests/__Snapshots__/CardTests/card.1.png", red)
        #expect(throws: SnapshotChangeError.noCommits) { try repo.git.snapshotChanges(baseBranch: "develop") }
    }

    @Test func missingBaseBranch() throws {
        let repo = try TempRepo()
        try repo.write("a", "a")
        try repo.commitAll("init")
        #expect(throws: SnapshotChangeError.self) { try repo.git.snapshotChanges(baseBranch: "nope") }
    }
}

@Suite struct ImageDiffTests {
    @Test func identicalAndChanged() throws {
        let a = PixelImage(data: png(width: 3, height: 2, rgba: (10, 20, 30, 255)))!
        #expect(ImageDiff.compare(a, a).isIdentical)

        var b = a
        b.pixels[(1 * 3 + 2) * 4] = 200 // pixel (2, 1)
        let diff = ImageDiff.compare(a, b)
        #expect(diff.changedPixels == 1)
        #expect(diff.changedBounds == CGRect(x: 2, y: 1, width: 1, height: 1))
        #expect(Array(diff.image.pixels[((1 * 3 + 2) * 4)..<((1 * 3 + 2) * 4 + 4)]) == [255, 0, 255, 255])
        #expect(ImageDiff.compare(a, b, tolerance: 255).isIdentical)
    }

    @Test func sizeChange() {
        let a = PixelImage(data: png(width: 2, height: 2, rgba: (0, 0, 0, 255)))!
        let b = PixelImage(data: png(width: 3, height: 2, rgba: (0, 0, 0, 255)))!
        let diff = ImageDiff.compare(a, b)
        #expect(diff.sizeChanged)
        #expect(diff.changedPixels == 2)
        #expect(diff.image.width == 3)
    }
}

@Suite struct ViewportTests {
    @Test func zoomAroundAnchorKeepsPointFixed() {
        var v = Viewport()
        let anchor = CGPoint(x: 100, y: -50)
        // Content point under the anchor, from the image's unshifted centre (`bottomBias / 2` above
        // the view's): (anchor - offset) / scale.
        func content() -> CGPoint {
            CGPoint(x: (anchor.x - v.offset.width) / v.scale, y: (anchor.y + Viewport.bottomBias / 2 - v.offset.height) / v.scale)
        }
        let before = content()
        v.zoom(by: 2, anchor: anchor)
        let after = content()
        #expect(v.scale == 2)
        #expect(before == after)
    }

    @Test func clampsAndResets() {
        var v = Viewport()
        for _ in 0..<100 { v.zoomIn() }
        #expect(v.scale == Viewport.maxScale)
        for _ in 0..<100 { v.zoomOut() }
        #expect(v.scale == Viewport.minScale)
        v.pan(by: CGSize(width: 5, height: 6))
        v.reset()
        #expect(v == Viewport())
        #expect(Viewport.fitScale(image: CGSize(width: 400, height: 200), in: CGSize(width: 200, height: 200)) == 0.5)
    }
}

/// A solid-color PNG.
func png(width: Int, height: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) -> Data {
    var pixels: [UInt8] = []
    for _ in 0..<(width * height) { pixels += [rgba.0, rgba.1, rgba.2, rgba.3] }
    return PixelImage(width: width, height: height, pixels: pixels).pngData()!
}

@Suite struct ReviewMarksTests {
    @Test func marksSurviveUntilTheSnapshotChangesAgain() throws {
        let repo = try TempRepo()
        let path = "Tests/AppTests/__Snapshots__/CardTests/card.1.png"
        try repo.write(path, png(width: 2, height: 2, rgba: (255, 0, 0, 255)))
        let card = SnapshotChange(path: path, kind: .new)
        let gone = SnapshotChange(path: "Tests/AppTests/__Snapshots__/CardTests/old.1.png", kind: .deleted)
        let marks = ReviewMarks(repository: repo.url)

        #expect(marks.viewed(in: [card, gone]).isEmpty)
        marks.set(true, for: card, keepingOnly: [card, gone])
        marks.set(true, for: gone, keepingOnly: [card, gone])
        #expect(marks.viewed(in: [card, gone]) == [card.id, gone.id])

        // Re-recorded with different pixels: needs another look.
        try repo.write(path, png(width: 2, height: 2, rgba: (0, 0, 255, 255)))
        #expect(marks.viewed(in: [card, gone]) == [gone.id])

        marks.set(false, for: gone, keepingOnly: [card, gone])
        #expect(marks.viewed(in: [card, gone]).isEmpty)

        // Marks for snapshots that are no longer changed are dropped.
        marks.set(true, for: card, keepingOnly: [card])
        #expect(marks.load().keys.sorted() == [path])
    }

    @Test func marksSeveralInOneGo() throws {
        let repo = try TempRepo()
        let paths = (1...3).map { "Tests/AppTests/__Snapshots__/CardTests/card.\($0).png" }
        for p in paths { try repo.write(p, png(width: 2, height: 2, rgba: (255, 0, 0, 255))) }
        let changes = paths.map { SnapshotChange(path: $0, kind: .new) }
        let marks = ReviewMarks(repository: repo.url)
        marks.set(true, for: changes, keepingOnly: changes)
        #expect(marks.viewed(in: changes) == Set(changes.map(\.id)))
        marks.set(false, for: Array(changes.prefix(2)), keepingOnly: changes)
        #expect(marks.viewed(in: changes) == [changes[2].id])
    }

    @Test func linkedWorktreesKeepTheirOwnMarks() throws {
        let repo = try TempRepo()
        try repo.write("README.md", "x")
        try repo.commitAll("init")
        let worktree = testTemp("worktree")
        try repo.git.run(["worktree", "add", "-q", "-b", "feature", worktree.path])
        let card = SnapshotChange(path: "Tests/AppTests/__Snapshots__/CardTests/card.1.png", kind: .deleted)

        let marks = ReviewMarks(repository: worktree)
        marks.set(true, for: card, keepingOnly: [card])
        #expect(ReviewMarks(repository: worktree).viewed(in: [card]) == [card.id])
        #expect(ReviewMarks(repository: repo.url).viewed(in: [card]).isEmpty)
        #expect(marks.url.path.hasPrefix(try repo.git.gitDirectory().path + "/worktrees/"))
    }
}

@Suite struct InvisibleChangesTests {
    @Test func findsReRecordsThatOnlyPickedUpNoise() throws {
        let repo = try TempRepo()
        let dir = "Tests/AppTests/__Snapshots__/CardTests"
        try repo.write("\(dir)/noise.1.png", png(width: 8, height: 8, rgba: (200, 200, 200, 255)))
        try repo.write("\(dir)/real.1.png", png(width: 8, height: 8, rgba: (200, 200, 200, 255)))
        try repo.commitAll("base")
        try repo.write("\(dir)/noise.1.png", png(width: 8, height: 8, rgba: (201, 200, 199, 255)))
        try repo.write("\(dir)/real.1.png", png(width: 8, height: 8, rgba: (255, 0, 0, 255)))

        let changes = [SnapshotChange(path: "\(dir)/noise.1.png", kind: .uncommitted),
                       SnapshotChange(path: "\(dir)/real.1.png", kind: .uncommitted),
                       SnapshotChange(path: "\(dir)/added.1.png", kind: .new)]
        #expect(repo.git.invisibleUncommittedChanges(changes).map(\.fileName) == ["noise.1.png"])
    }
}
