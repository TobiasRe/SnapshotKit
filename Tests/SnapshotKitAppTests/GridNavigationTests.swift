import SnapshotKitCore
import SwiftUI
import Testing
@testable import SnapshotKitUI

/// ↑ and ↓ in the library's grid move by a row as you see it: each suite starts a row of its own.
struct GridNavigationTests {
    // Two suites in a grid four tiles wide: a, b, c, d / e, f   then   g, h, i
    let rows = SnapshotGrid.rows([["a", "b", "c", "d", "e", "f"], ["g", "h", "i"]], perRow: 4)

    @Test func eachSectionStartsARow() {
        #expect(rows == [["a", "b", "c", "d"], ["e", "f"], ["g", "h", "i"]])
    }

    @Test func downKeepsTheColumnAcrossSections() {
        #expect(SnapshotGrid.vertical(from: "b", by: 1, in: rows) == "f")
        #expect(SnapshotGrid.vertical(from: "e", by: 1, in: rows) == "g")     // the next suite's first tile
        #expect(SnapshotGrid.vertical(from: "f", by: 1, in: rows) == "h")
    }

    @Test func aShorterRowTakesItsLastTile() {
        #expect(SnapshotGrid.vertical(from: "d", by: 1, in: rows) == "f")
        #expect(SnapshotGrid.vertical(from: "i", by: -1, in: rows) == "f")
    }

    @Test func theEdgesStayPut() {
        #expect(SnapshotGrid.vertical(from: "c", by: -1, in: rows) == nil)
        #expect(SnapshotGrid.vertical(from: "h", by: 1, in: rows) == nil)
    }

    /// The arrows look around a zoomed-in image, and leave the keys alone at fit.
    @Test func arrowsPanOnlyWhenZoomedIn() {
        var fit = Viewport()
        let panned = fit.pan(arrow: .leftArrow)
        #expect(!panned && fit == Viewport())
        var zoomed = Viewport(scale: 3, offset: .zero)
        _ = zoomed.pan(arrow: .leftArrow)
        #expect(zoomed.offset == CGSize(width: 80, height: 0))
        _ = zoomed.pan(arrow: .downArrow)
        #expect(zoomed.offset == CGSize(width: 80, height: -80))
        let space = zoomed.pan(arrow: .space)
        #expect(!space)
    }
}
