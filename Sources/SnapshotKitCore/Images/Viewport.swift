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
        // A point p (from center) maps to p' = anchor + (p - anchor) * applied.
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

    /// Scale at which an image of `imageSize` fits entirely in `viewSize`.
    public static func fitScale(image imageSize: CGSize, in viewSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return min(viewSize.width / imageSize.width, viewSize.height / imageSize.height, 1)
    }
}
