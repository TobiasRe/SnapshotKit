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
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .task(id: id) {
            if let cached = ThumbnailCache.shared.object(forKey: id as NSString) {
                image = cached
                return
            }
            let load = load
            let decoded = await Task.detached { ThumbnailCache.decode(load()) }.value
            if let decoded { ThumbnailCache.shared.setObject(decoded, forKey: id as NSString) }
            image = decoded
        }
    }
}

enum ThumbnailCache {
    static let shared = NSCache<NSString, NSImage>()

    /// Decodes and caches a thumbnail synchronously (snapshot tests).
    static func preload(id: String, data: Data?) {
        if let image = decode(data) { shared.setObject(image, forKey: id as NSString) }
    }

    static func decode(_ data: Data?) -> NSImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
