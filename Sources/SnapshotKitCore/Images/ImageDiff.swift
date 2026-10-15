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

public struct ImageDiffResult: Sendable {
    /// Changed pixels in magenta over a faded grayscale of the base image.
    public var image: PixelImage
    public var changedPixels: Int
    public var totalPixels: Int
    public var sizeChanged: Bool
    /// Bounding box of changed pixels (top-left origin), nil if identical.
    public var changedBounds: CGRect?

    public var changedFraction: Double { totalPixels == 0 ? 0 : Double(changedPixels) / Double(totalPixels) }
    public var isIdentical: Bool { changedPixels == 0 && !sizeChanged }
}

public enum ImageDiff {
    /// Compares two images pixel by pixel. Channels differing by at most `tolerance` count as equal.
    /// Images of different sizes are compared over the union canvas (missing area counts as changed).
    public static func compare(_ a: PixelImage, _ b: PixelImage, tolerance: UInt8 = 0) -> ImageDiffResult {
        let w = max(a.width, b.width), h = max(a.height, b.height)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        var changed = 0
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
            changedBounds: bounds
        )
    }
}
