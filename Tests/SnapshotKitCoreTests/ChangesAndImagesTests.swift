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
        #expect(set.groups.map(\.suite) == ["CardTests", "ListTests"])
        #expect(repo.git.baseImage(for: set.changes.first { $0.fileName == "committed.1.png" }!, in: set) == red)
        #expect(repo.git.currentImage(for: set.changes.first { $0.fileName == "deleted.1.png" }!) == nil)

        // Against the tip, develop's own change appears too.
        let tip = try repo.git.snapshotChanges(baseBranch: "develop", against: .tip)
        #expect(tip.changes.contains { $0.fileName == "same.1.png" })
    }

    @Test func filterAndNames() {
        let changes = [
            SnapshotChange(path: "T/__Snapshots__/CardTests/darkMode.1.png", kind: .committed),
            SnapshotChange(path: "T/__Snapshots__/ListTests/empty.2.png", kind: .new),
        ]
        #expect(SnapshotChangeSet.filter(changes, text: "card dark").map(\.testName) == ["darkMode"])
        #expect(SnapshotChangeSet.filter(changes, text: "", kinds: [.new]).map(\.suite) == ["ListTests"])
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
        // Content point under the anchor, in image coordinates: (anchor - offset) / scale.
        let before = CGPoint(x: (anchor.x - v.offset.width) / v.scale, y: (anchor.y - v.offset.height) / v.scale)
        v.zoom(by: 2, anchor: anchor)
        let after = CGPoint(x: (anchor.x - v.offset.width) / v.scale, y: (anchor.y - v.offset.height) / v.scale)
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
