import CoreGraphics
import Testing
@testable import SnapshotKitCore

@Suite struct DiffDiagnosisTests {
    /// A 100×100 image of one colour, with optional pixels painted another colour.
    func image(_ base: (UInt8, UInt8, UInt8), painting count: Int = 0, with color: (UInt8, UInt8, UInt8) = (0, 0, 0),
               width: Int = 100, height: Int = 100) -> PixelImage {
        var pixels = [UInt8]()
        for i in 0..<(width * height) {
            let c = i < count ? color : base
            pixels += [c.0, c.1, c.2, 255]
        }
        return PixelImage(width: width, height: height, pixels: pixels)
    }

    @Test func identical() {
        let a = image((200, 200, 200))
        #expect(DiffDiagnosis(ImageDiff.compare(a, a)).kind == .identical)
    }

    @Test func renderingNoiseIsImperceptibleAndSuggestsPerceptualPrecision() {
        // Every pixel off by one step: fails an exact comparison, invisible to the eye.
        let diff = ImageDiff.compare(image((200, 200, 200)), image((201, 200, 199)))
        #expect(diff.changedPixels == 10_000)
        #expect(diff.maxPerceptualDelta > 0 && diff.maxPerceptualDelta < 2.3)
        let d = DiffDiagnosis(diff)
        #expect(d.kind == .imperceptible)
        #expect(d.suggestion == "perceptualPrecision: 0.99")
    }

    /// swift-snapshot-testing only compares perceptually below 1, so 1 would never pass.
    @Test func aDifferenceOnlyInTransparencySuggestsAPrecisionBelowOne() {
        let clear = PixelImage(width: 1, height: 1, pixels: [0, 0, 0, 0])
        let faint = PixelImage(width: 1, height: 1, pixels: [0, 0, 0, 3])
        let d = DiffDiagnosis(ImageDiff.compare(clear, faint))
        #expect(d.kind == .imperceptible)
        #expect(d.suggestion == "perceptualPrecision: 0.99")
    }

    @Test func aFewVisiblePixelsAreTiny() {
        let diff = ImageDiff.compare(image((255, 255, 255)), image((255, 255, 255), painting: 3))
        #expect(diff.perceptiblePixels == 3)
        let d = DiffDiagnosis(diff)
        #expect(d.kind == .tiny)
        #expect(d.suggestion == "precision: 0.9997")
        #expect(d.summary.hasPrefix("3 visible pixels changed in a 3×1 px area"))
    }

    @Test func largeChangesAreVisible() {
        let diff = ImageDiff.compare(image((255, 255, 255)), image((255, 255, 255), painting: 2000, with: (255, 0, 0)))
        let d = DiffDiagnosis(diff)
        #expect(d.kind == .visible)
        #expect(d.suggestion == nil)
        #expect(diff.maxPerceptualDelta > 50)
    }

    @Test func sizeChangeWins() {
        let diff = ImageDiff.compare(image((0, 0, 0)), image((0, 0, 0), width: 100, height: 120))
        #expect(DiffDiagnosis(diff).kind == .sizeChanged)
    }

    @Test func deltaEMatchesKnownValues() {
        // Black vs white is ΔE 100 in every CIE formula.
        let black = Lab([0, 0, 0, 255], 0), white = Lab([255, 255, 255, 255], 0)
        #expect(abs(Lab.deltaE94(black, white) - 100) < 0.1)
        #expect(Lab.deltaE94(white, white) == 0)
    }
}

@Suite struct ViewportPlacementTests {
    let image = CGSize(width: 400, height: 800)
    let canvas = CGSize(width: 648, height: 1040)

    @Test func fitsAboveTheControlBar() {
        let rect = Viewport().imageRect(imageSize: image, canvas: canvas)
        // 1040 - 120 leaves 920 points: the image fits at full size, centred above the bar.
        #expect(rect == CGRect(x: 124, y: 100, width: 400, height: 800))
    }

    @Test func pixelUnderPointFollowsZoomAndPan() {
        var v = Viewport()
        #expect(v.pixel(at: CGPoint(x: 124, y: 100), imageSize: image, canvas: canvas)! == (0, 0))
        #expect(v.pixel(at: CGPoint(x: 10, y: 10), imageSize: image, canvas: canvas) == nil)
        v.zoom(by: 2)
        let rect = v.imageRect(imageSize: image, canvas: canvas)
        let p = v.pixel(at: CGPoint(x: rect.minX + 21, y: rect.minY + 41), imageSize: image, canvas: canvas)!
        #expect(p == (10, 20))
    }

    @Test func focusingCentresAndZoomsIntoTheRegion() {
        let region = CGRect(x: 300, y: 600, width: 10, height: 10)
        let v = Viewport.focusing(on: region, imageSize: image, canvas: canvas)
        #expect(v.scale > 4)
        let rect = v.imageRect(imageSize: image, canvas: canvas)
        let s = rect.width / image.width
        let centre = CGPoint(x: rect.minX + region.midX * s, y: rect.minY + region.midY * s)
        #expect(abs(centre.x - canvas.width / 2) < 0.01)
        #expect(abs(centre.y - (canvas.height - Viewport.bottomBias) / 2) < 0.01)
    }

    @Test func focusingOnEverythingJustFits() {
        let v = Viewport.focusing(on: CGRect(origin: .zero, size: image), imageSize: image, canvas: canvas)
        #expect(v.scale == 1)
        #expect(v.offset == .zero)
    }
}

@Suite struct PixelColorTests {
    @Test func readsAndFormatsPixels() {
        let image = PixelImage(width: 2, height: 1, pixels: [255, 0, 0, 255, 0, 128, 255, 64])
        #expect(image.color(x: 0, y: 0)?.hex == "#FF0000")
        #expect(image.color(x: 1, y: 0)?.hex == "#0080FF40")
        #expect(image.color(x: 2, y: 0) == nil)
        #expect(image.color(x: 0, y: 0)!.perceptualDistance(to: image.color(x: 0, y: 0)!) == 0)
    }
}

@Suite struct ImageComposerTests {
    @Test func placesImagesSideBySideWithSpacing() throws {
        let red = PixelImage(width: 2, height: 3, pixels: Array(repeating: [255, 0, 0, 255], count: 6).flatMap { $0 })
        let blue = PixelImage(width: 1, height: 1, pixels: [0, 0, 255, 255])
        let out = try #require(ImageComposer.sideBySide([red, blue], spacing: 1))
        #expect(out.width == 2 + 1 + 3)   // 1 + red + 1 + blue + 1
        #expect(out.height == 3 + 2)
        #expect(out.color(x: 0, y: 0)?.hex == "#FFFFFF")
        #expect(out.color(x: 1, y: 1)?.hex == "#FF0000")
        #expect(out.color(x: 4, y: 1)?.hex == "#0000FF")
        #expect(out.color(x: 4, y: 2)?.hex == "#FFFFFF")   // below the shorter image
    }
}
