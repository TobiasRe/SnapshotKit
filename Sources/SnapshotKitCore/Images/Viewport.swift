import CoreGraphics

/// Zoom and pan state shared by all compare modes, kept free of UI types so it can be tested.
/// `offset` is in view points; the image is drawn centered, scaled by `scale`, then shifted by `offset`.
public struct Viewport: Equatable, Sendable {
    public static let minScale: CGFloat = 0.1
    public static let maxScale: CGFloat = 32
    public static let step: CGFloat = 1.25

    public var scale: CGFloat = 1
    public var offset: CGSize = .zero

    public init(scale: CGFloat = 1, offset: CGSize = .zero) {
        self.scale = scale
        self.offset = offset
    }

    /// Zooms by `factor`, keeping the content under `anchor` (relative to the view center) fixed.
    public mutating func zoom(by factor: CGFloat, anchor: CGPoint = .zero) {
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        let applied = newScale / scale
        // Relative to where an unshifted image is centred, `bottomBias / 2` above the view's centre.
        let anchor = CGPoint(x: anchor.x, y: anchor.y + Self.bottomBias / 2)
        // A point p (from that centre) maps to p' = anchor + (p - anchor) * applied.
        offset = CGSize(
            width: anchor.x + (offset.width - anchor.x) * applied,
            height: anchor.y + (offset.height - anchor.y) * applied
        )
        scale = newScale
    }

    public mutating func zoomIn() { zoom(by: Self.step) }
    public mutating func zoomOut() { zoom(by: 1 / Self.step) }

    public mutating func pan(by delta: CGSize) {
        offset.width += delta.width
        offset.height += delta.height
    }

    public mutating func reset() { self = Viewport() }

    // MARK: Placing an image in a canvas

    /// Room kept free around a fitted image for the floating captions and control bar.
    public static let fitInsets = CGSize(width: 48, height: 120)
    /// The image is centred above the control bar rather than in the whole canvas.
    public static let bottomBias: CGFloat = 40

    /// Where an image of `imageSize` pixels is drawn in a canvas of `canvas` points.
    public func imageRect(imageSize: CGSize, canvas: CGSize) -> CGRect {
        let fit = Self.fitScale(image: imageSize, in: CGSize(width: canvas.width - Self.fitInsets.width,
                                                             height: canvas.height - Self.fitInsets.height))
        let s = fit * scale
        let drawn = CGSize(width: imageSize.width * s, height: imageSize.height * s)
        return CGRect(x: canvas.width / 2 + offset.width - drawn.width / 2,
                      y: (canvas.height - Self.bottomBias) / 2 + offset.height - drawn.height / 2,
                      width: drawn.width, height: drawn.height)
    }

    /// The image pixel under `point` (canvas points, top-left origin), or nil outside the image.
    public func pixel(at point: CGPoint, imageSize: CGSize, canvas: CGSize) -> (x: Int, y: Int)? {
        let rect = imageRect(imageSize: imageSize, canvas: canvas)
        guard rect.width > 0, rect.contains(point) else { return nil }
        let x = Int((point.x - rect.minX) / rect.width * imageSize.width)
        let y = Int((point.y - rect.minY) / rect.height * imageSize.height)
        return (min(x, Int(imageSize.width) - 1), min(y, Int(imageSize.height) - 1))
    }

    /// A viewport that centres `region` (image pixels) and zooms so it fills about `fill` of the
    /// canvas. Never zooms out below fit: a change spanning the whole image just fits.
    public static func focusing(on region: CGRect, imageSize: CGSize, canvas: CGSize, fill: CGFloat = 0.5) -> Viewport {
        let fit = fitScale(image: imageSize, in: CGSize(width: canvas.width - fitInsets.width,
                                                        height: canvas.height - fitInsets.height))
        let available = CGSize(width: canvas.width - fitInsets.width, height: canvas.height - fitInsets.height)
        let regionScale = min(available.width * fill / max(region.width, 1), available.height * fill / max(region.height, 1))
        let zoom = min(max(regionScale / fit, 1), maxScale)
        let s = fit * zoom
        return Viewport(scale: zoom, offset: CGSize(width: s * (imageSize.width / 2 - region.midX),
                                                    height: s * (imageSize.height / 2 - region.midY)))
    }

    /// Scale at which an image of `imageSize` fits entirely in `viewSize`.
    public static func fitScale(image imageSize: CGSize, in viewSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return min(viewSize.width / imageSize.width, viewSize.height / imageSize.height, 1)
    }
}
