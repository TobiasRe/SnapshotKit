import AppKit
import ImageIO
import SwiftUI

/// Small, cached preview of a snapshot for list rows. Decoding happens off the main thread.
struct Thumbnail: View {
    var id: String
    var load: @Sendable () -> Data?
    var size = CGSize(width: 48, height: 34)

    @State private var image: NSImage?

    init(id: String, size: CGSize = CGSize(width: 48, height: 34), load: @escaping @Sendable () -> Data?) {
        // Larger tiles (the library grid) decode at their own resolution under their own key.
        let maxPixel = ThumbnailCache.maxPixel(for: size)
        let id = maxPixel == ThumbnailCache.defaultMaxPixel ? id : id + "@\(maxPixel)"
        self.id = id
        self.size = size
        self.load = load
        _image = State(initialValue: ThumbnailCache.shared.object(forKey: id as NSString))
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .accessibilityHidden(true)
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .task(id: id) {
            if let cached = ThumbnailCache.shared.object(forKey: id as NSString) {
                image = cached
                return
            }
            let load = load, maxPixel = ThumbnailCache.maxPixel(for: size)
            let decoded = await Task.detached { ThumbnailCache.decode(load(), maxPixel: maxPixel) }.value
            if let decoded { ThumbnailCache.shared.setObject(decoded, forKey: id as NSString) }
            image = decoded
        }
    }
}

enum ThumbnailCache {
    /// NSCache is thread-safe (thumbnails are made off the main thread).
    nonisolated(unsafe) static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    /// Decodes and caches a thumbnail synchronously (snapshot tests).
    static func preload(id: String, data: Data?, size: CGSize? = nil) {
        let maxPixel = size.map(maxPixel(for:)) ?? defaultMaxPixel
        let key = maxPixel == defaultMaxPixel ? id : id + "@\(maxPixel)"
        if let image = decode(data, maxPixel: maxPixel) { shared.setObject(image, forKey: key as NSString) }
    }

    static let defaultMaxPixel = 160

    /// Twice the tile's longer side (Retina), never below the list size.
    static func maxPixel(for size: CGSize) -> Int {
        max(defaultMaxPixel, Int(max(size.width, size.height) * 2))
    }

    static func decode(_ data: Data?, maxPixel: Int = defaultMaxPixel) -> NSImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
