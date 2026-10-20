import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SnapshotKitCore

/// Images at the edges: one pixel, transparency, sizes that differ both ways, other PNG pixel
/// formats, and the largest snapshots in practice.
@Suite struct ImageEdgeTests {
    func solid(_ width: Int, _ height: Int, _ rgba: (UInt8, UInt8, UInt8, UInt8)) -> PixelImage {
        var pattern = [rgba.0, rgba.1, rgba.2, rgba.3]
        let pixels = [UInt8](unsafeUninitializedCapacity: width * height * 4) { buffer, count in
            memset_pattern4(buffer.baseAddress!, &pattern, buffer.count)
            count = buffer.count
        }
        return PixelImage(width: width, height: height, pixels: pixels)
    }

    @Test func onePixel() throws {
        let white = try #require(PixelImage(data: png(width: 1, height: 1, rgba: (255, 255, 255, 255))))
        let black = try #require(PixelImage(data: png(width: 1, height: 1, rgba: (0, 0, 0, 255))))
        #expect(DiffDiagnosis(ImageDiff.compare(white, white)) == DiffDiagnosis(ImageDiff.compare(solid(1, 1, (255, 255, 255, 255)), solid(1, 1, (255, 255, 255, 255)))))
        #expect(DiffDiagnosis(ImageDiff.compare(white, white)).kind == .identical)
        let diff = ImageDiff.compare(white, black)
        #expect((diff.changedPixels, diff.totalPixels, diff.changedFraction) == (1, 1, 1))
        #expect(diff.changedBounds == CGRect(x: 0, y: 0, width: 1, height: 1))
        let diagnosis = DiffDiagnosis(diff)
        #expect(diagnosis.kind == .visible)
        #expect(diagnosis.summary == "Visible change in a 1×1 area at 0, 0.")
        #expect(diagnosis.suggestion == nil)
    }

    /// A pixel nobody can see is the same pixel whatever colour it was drawn in.
    @Test func fullyTransparentPixelsOfDifferentColoursAreEqual() throws {
        let red = try #require(PixelImage(data: png(width: 2, height: 2, rgba: (255, 0, 0, 0))))
        let blue = try #require(PixelImage(data: png(width: 2, height: 2, rgba: (0, 0, 255, 0))))
        #expect(red.color(x: 0, y: 0) == PixelColor(r: 0, g: 0, b: 0, a: 0))
        #expect(ImageDiff.compare(red, blue).isIdentical)
    }

    /// Half-transparent red over nothing is darker than opaque red: a visible change.
    @Test func translucencyIsAVisibleChange() throws {
        let opaque = try #require(PixelImage(data: png(width: 2, height: 2, rgba: (255, 0, 0, 255))))
        let half = try #require(PixelImage(data: png(width: 2, height: 2, rgba: (255, 0, 0, 128))))
        let diff = ImageDiff.compare(opaque, half)
        #expect(diff.changedPixels == 4 && diff.perceptiblePixels == 4)
        #expect(DiffDiagnosis(diff).kind == .visible)
    }

    /// Wider and shorter: the union is compared, and a pixel neither image has isn't a change.
    @Test func sizesThatDifferBothWays() {
        let tall = solid(2, 3, (0, 0, 0, 255)), wide = solid(3, 2, (0, 0, 0, 255))
        let diff = ImageDiff.compare(tall, wide)
        #expect(diff.sizeChanged)
        #expect((diff.image.width, diff.image.height, diff.totalPixels) == (3, 3, 9))
        #expect(diff.changedPixels == 4)
        #expect(diff.perceptiblePixels == 4)
        #expect(diff.changedBounds == CGRect(x: 0, y: 0, width: 3, height: 3))
        let magenta = [(2, 0), (2, 1), (0, 2), (1, 2)]
        for y in 0..<3 {
            for x in 0..<3 {
                #expect((diff.image.color(x: x, y: y)?.hex == "#FF00FF") == magenta.contains { $0 == (x, y) }, "(\(x), \(y))")
            }
        }
        #expect(DiffDiagnosis(diff).kind == .sizeChanged)
        #expect(DiffDiagnosis(diff).suggestion == nil)
        #expect(ImageDiff.compare(wide, tall).changedPixels == 4)
    }

    @Test func dataThatIsNoImage() {
        #expect(PixelImage(data: Data()) == nil)
        #expect(PixelImage(data: Data("not a png".utf8)) == nil)
        #expect(PixelImage(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == nil) // a PNG signature alone
    }

    /// A grayscale or 16-bit PNG (what other tools write) compares equal to the 8-bit RGBA
    /// image of the same colour.
    enum Format: String, CaseIterable, Sendable { case gray8, rgba16 }

    @Test(arguments: Format.allCases)
    func otherPixelFormats(_ format: Format) throws {
        let (space, bits, alpha) = format == .gray8
            ? (CGColorSpaceCreateDeviceGray(), 8, CGImageAlphaInfo.none.rawValue)
            : (CGColorSpace(name: CGColorSpace.sRGB)!, 16, CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: alpha))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let decoded = try #require(PixelImage(data: data as Data))
        #expect((decoded.width, decoded.height) == (4, 4))
        #expect(ImageDiff.compare(decoded, solid(4, 4, (255, 255, 255, 255))).isIdentical)
    }

    /// `tiny` means fewer than one in a thousand pixels visibly changed.
    @Test func whereTinyEnds() {
        let line = solid(1000, 1, (255, 255, 255, 255))
        var one = line
        one.pixels[0] = 0
        #expect(DiffDiagnosis(ImageDiff.compare(line, one)).kind == .visible)    // 1 in 1000
        let longer = solid(1001, 1, (255, 255, 255, 255))
        var oneOfMore = longer
        oneOfMore.pixels[0] = 0
        let diagnosis = DiffDiagnosis(ImageDiff.compare(longer, oneOfMore))   // 1 in 1001
        #expect(diagnosis.kind == .tiny)
        #expect(diagnosis.suggestion == "precision: 0.999")
        #expect(diagnosis.summary == "1 visible pixel changed in a 1×1 px area: often anti-aliasing, a caret or a timestamp.")
    }

    /// An iPad screen's worth of pixels (1.4 million), one changed in the far corner: positions and
    /// fractions stay exact. (A debug build compares about a pixel a microsecond, so a 2× iPad
    /// snapshot would take seconds here.)
    @Test(.timeLimit(.minutes(1)))
    func aMillionPixelSnapshot() {
        let (width, height) = (1024, 1366)
        let reference = solid(width, height, (240, 240, 240, 255))
        var actual = reference
        actual.pixels[actual.pixels.count - 4] = 0
        let diff = ImageDiff.compare(reference, actual)
        #expect((diff.changedPixels, diff.totalPixels) == (1, width * height))
        #expect(diff.changedBounds == CGRect(x: width - 1, y: height - 1, width: 1, height: 1))
        let diagnosis = DiffDiagnosis(diff)
        #expect(diagnosis.kind == .tiny)
        #expect(diagnosis.suggestion == "precision: 0.9999")
    }
}
