import Foundation

/// Combines images into one, for pasting a comparison into a review or chat.
public enum ImageComposer {
    /// Images next to each other, top-aligned, separated by `spacing` pixels of `background`.
    public static func sideBySide(_ images: [PixelImage], spacing: Int = 24,
                                  background: PixelColor = PixelColor(r: 255, g: 255, b: 255)) -> PixelImage? {
        guard !images.isEmpty else { return nil }
        let width = images.reduce(0) { $0 + $1.width } + spacing * (images.count + 1)
        let height = (images.map(\.height).max() ?? 0) + spacing * 2
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = background.r; pixels[i + 1] = background.g; pixels[i + 2] = background.b; pixels[i + 3] = background.a
        }
        var x0 = spacing
        for image in images {
            for y in 0..<image.height {
                let src = y * image.width * 4, dst = ((y + spacing) * width + x0) * 4
                pixels.replaceSubrange(dst..<(dst + image.width * 4), with: image.pixels[src..<(src + image.width * 4)])
            }
            x0 += image.width + spacing
        }
        return PixelImage(width: width, height: height, pixels: pixels)
    }
}
