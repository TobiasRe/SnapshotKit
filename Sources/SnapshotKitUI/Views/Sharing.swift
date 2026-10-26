import AppKit
import SnapshotKitCore

/// Putting snapshots on the clipboard, for pasting into a pull request, issue or chat.
enum Clipboard {
    static func copyImage(_ data: Data) {
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.png, .tiff], owner: nil)
        board.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation { board.setData(tiff, forType: .tiff) }
    }

    /// Before, after and the difference in one image. Decodes and composes off the main thread.
    static func copyComparison(_ load: @escaping @Sendable () -> (Data?, Data?)) {
        Task {
            let png = await Task.detached { () -> Data? in
                let (before, after) = load()
                let a = before.flatMap(PixelImage.init(data:)), b = after.flatMap(PixelImage.init(data:))
                var images = [a, b].compactMap { $0 }
                if let a, let b { images.append(ImageDiff.compare(a, b).image) }
                return ImageComposer.sideBySide(images)?.pngData()
            }.value
            if let png { copyImage(png) }
        }
    }
}
