import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// RGBA8 pixel buffer, the common ground for comparing PNGs.
public struct PixelImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "\(pixels.count) bytes are not \(width)×\(height) RGBA pixels")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(cgImage: image)
    }

    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w
        height = h
        pixels = buffer
    }

    /// The pixel at (x, y), top-left origin, or nil outside the image.
    public func color(x: Int, y: Int) -> PixelColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        return PixelColor(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2], a: pixels[i + 3])
    }

    public var cgImage: CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func pngData() -> Data? {
        guard let image = cgImage else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

public struct PixelColor: Equatable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// `#RRGGBB`, plus the alpha byte when it isn't opaque.
    public var hex: String {
        let rgb = String(format: "#%02X%02X%02X", r, g, b)
        return a == 255 ? rgb : rgb + String(format: "%02X", a)
    }

    /// CIE94 difference to another colour (below ~2.3 is invisible).
    public func perceptualDistance(to other: PixelColor) -> Double {
        Lab.deltaE94(Lab([r, g, b, a], 0), Lab([other.r, other.g, other.b, other.a], 0))
    }
}

public struct ImageDiffResult: Sendable {
    /// Changed pixels in magenta over a faded grayscale of the base image.
    public var image: PixelImage
    public var changedPixels: Int
    public var totalPixels: Int
    public var sizeChanged: Bool
    /// Bounding box of changed pixels (top-left origin), nil if identical.
    public var changedBounds: CGRect?
    /// Largest CIE94 colour difference of any pixel present in both images (0 = identical,
    /// below ~2.3 is invisible to the eye). This is the measure `perceptualPrecision` uses.
    public var maxPerceptualDelta: Double = 0
    /// Pixels whose difference is visible (ΔE ≥ 2.3), plus pixels only one image has.
    public var perceptiblePixels: Int = 0

    public var changedFraction: Double { totalPixels == 0 ? 0 : Double(changedPixels) / Double(totalPixels) }
    public var isIdentical: Bool { changedPixels == 0 && !sizeChanged }
}

public enum ImageDiff {
    /// Compares two images pixel by pixel. Channels differing by at most `tolerance` count as equal.
    /// Images of different sizes are compared over the union canvas (missing area counts as changed).
    public static func compare(_ a: PixelImage, _ b: PixelImage, tolerance: UInt8 = 0) -> ImageDiffResult {
        let w = max(a.width, b.width), h = max(a.height, b.height)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        var changed = 0, perceptible = 0
        var maxDelta = 0.0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                let inA = x < a.width && y < a.height, inB = x < b.width && y < b.height
                var differs = inA != inB
                var gray: UInt8 = 255
                if inA {
                    let ia = (y * a.width + x) * 4
                    let r = Int(a.pixels[ia]), g = Int(a.pixels[ia + 1]), bl = Int(a.pixels[ia + 2])
                    gray = UInt8((r * 30 + g * 59 + bl * 11) / 100)
                    if inB {
                        let ib = (y * b.width + x) * 4
                        for c in 0..<4 where abs(Int(a.pixels[ia + c]) - Int(b.pixels[ib + c])) > Int(tolerance) {
                            differs = true
                            break
                        }
                    }
                }
                if differs {
                    if inA && inB {
                        let ia = (y * a.width + x) * 4, ib = (y * b.width + x) * 4
                        let delta = Lab.deltaE94(Lab(a.pixels, ia), Lab(b.pixels, ib))
                        maxDelta = max(maxDelta, delta)
                        if delta >= Lab.justNoticeable { perceptible += 1 }
                    } else {
                        perceptible += 1
                    }
                    changed += 1
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    out[o] = 255; out[o + 1] = 0; out[o + 2] = 255; out[o + 3] = 255
                } else {
                    // Faded context so the changes stand out.
                    let faded = UInt8(160 + Int(gray) * 95 / 255)
                    out[o] = faded; out[o + 1] = faded; out[o + 2] = faded; out[o + 3] = 255
                }
            }
        }
        let bounds = maxX >= 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil
        return ImageDiffResult(
            image: PixelImage(width: w, height: h, pixels: out),
            changedPixels: changed,
            totalPixels: w * h,
            sizeChanged: a.width != b.width || a.height != b.height,
            changedBounds: bounds,
            maxPerceptualDelta: maxDelta,
            perceptiblePixels: perceptible
        )
    }
}

/// CIE L*a*b* from 8-bit sRGB (D65), enough to reproduce `perceptualPrecision`.
struct Lab {
    static let justNoticeable = 2.3
    var l: Double, a: Double, b: Double

    init(_ pixels: [UInt8], _ i: Int) {
        func linear(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(pixels[i]), g = linear(pixels[i + 1]), bl = linear(pixels[i + 2])
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * bl
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        l = 116 * f(y) - 16
        a = 500 * (f(x) - f(y))
        b = 200 * (f(y) - f(z))
    }

    /// CIE94 (graphic arts weights), as Core Image's `CILabDeltaE` computes it.
    static func deltaE94(_ p: Lab, _ q: Lab) -> Double {
        let dl = p.l - q.l
        let c1 = (p.a * p.a + p.b * p.b).squareRoot(), c2 = (q.a * q.a + q.b * q.b).squareRoot()
        let dc = c1 - c2
        let da = p.a - q.a, db = p.b - q.b
        let dh2 = max(da * da + db * db - dc * dc, 0)
        let sc = 1 + 0.045 * c1, sh = 1 + 0.015 * c1
        return (dl * dl + (dc / sc) * (dc / sc) + dh2 / (sh * sh)).squareRoot()
    }
}
