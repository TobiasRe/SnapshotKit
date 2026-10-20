import CoreGraphics
import Foundation

/// What kind of difference a snapshot failure is, and the most lenient swift-snapshot-testing
/// setting that would let it pass. Meant to tell rendering noise apart from real UI changes.
public struct DiffDiagnosis: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case identical
        /// Width or height differ: a different device, scale or layout.
        case sizeChanged
        /// Pixels differ, but no pixel differs visibly (ΔE below 2.3).
        case imperceptible
        /// A handful of visible pixels: anti-aliasing, a caret, a timestamp.
        case tiny
        /// A real, visible change.
        case visible
    }

    public var kind: Kind
    /// One sentence for people.
    public var summary: String
    /// A `perceptualPrecision` value that would make this comparison pass, if one is reasonable.
    public var suggestedPerceptualPrecision: Double?
    /// A `precision` value that would make this comparison pass, if one is reasonable.
    public var suggestedPrecision: Double?

    /// Visible changes below this share of pixels count as `tiny`.
    public static let tinyFraction = 0.001

    public init(_ result: ImageDiffResult) {
        suggestedPerceptualPrecision = nil
        suggestedPrecision = nil
        let delta = String(format: "%.1f", result.maxPerceptualDelta)
        if result.isIdentical {
            kind = .identical
            summary = "The images are pixel-identical."
        } else if result.sizeChanged {
            kind = .sizeChanged
            summary = "The image size changed, so the device, scale or layout differs from the reference."
        } else if result.maxPerceptualDelta < Lab.justNoticeable {
            kind = .imperceptible
            // Round down so the suggestion really passes, and stay below 1, where swift-snapshot-testing
            // compares exactly (pixels can differ with ΔE 0, in transparency).
            suggestedPerceptualPrecision = min(Self.floor(1 - result.maxPerceptualDelta / 100, places: 2), 0.99)
            summary = "No visible difference (largest ΔE \(delta)), typical of rendering on another machine or OS version."
        } else if Double(result.perceptiblePixels) / Double(max(result.totalPixels, 1)) < Self.tinyFraction {
            kind = .tiny
            suggestedPrecision = Self.floor(1 - result.changedFraction, places: 4)
            let size = result.changedBounds.map { "\(Int($0.width))×\(Int($0.height)) px area" } ?? "small area"
            summary = "\(result.perceptiblePixels) visible pixel\(result.perceptiblePixels == 1 ? "" : "s") changed in a \(size): often anti-aliasing, a caret or a timestamp."
        } else {
            kind = .visible
            if let b = result.changedBounds {
                summary = "Visible change in a \(Int(b.width))×\(Int(b.height)) area at \(Int(b.minX)), \(Int(b.minY))."
            } else {
                summary = "Visible change."
            }
        }
    }

    /// The trait to paste into the test, e.g. `perceptualPrecision: 0.98`.
    public var suggestion: String? {
        if let p = suggestedPerceptualPrecision { return "perceptualPrecision: \(Self.format(p))" }
        if let p = suggestedPrecision { return "precision: \(Self.format(p))" }
        return nil
    }

    static func floor(_ value: Double, places: Int) -> Double {
        let m = pow(10, Double(places))
        return (value * m).rounded(.down) / m
    }

    static func format(_ value: Double) -> String {
        var s = String(format: "%.4f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
