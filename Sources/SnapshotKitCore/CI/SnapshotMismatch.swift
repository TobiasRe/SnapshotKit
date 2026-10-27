import Foundation

/// What a swift-snapshot-testing failure message says about one assertion: where the reference and the
/// image just taken were (on the machine that ran the test), and the precision measured against the
/// precision required. Free text, so anything may be missing.
public struct SnapshotMismatch: Equatable, Sendable {
    public struct Precision: Equatable, Sendable {
        public var actual: Double
        public var required: Double
    }

    /// Absolute path of the reference PNG, under `__Snapshots__`.
    public var reference: String?
    /// Absolute path of the image the test took, in the simulator's temporary folder.
    public var actual: String?
    /// The share of pixels that match (`precision:`).
    public var pixels: Precision?
    /// How closely the least matching pixel matches (`perceptualPrecision:`).
    public var perceptual: Precision?
    /// The sizes, when they differ: `(390.0, 844.0)` and the reference's.
    public var sizes: (actual: String, reference: String)?

    public init(reference: String? = nil, actual: String? = nil, pixels: Precision? = nil, perceptual: Precision? = nil,
                sizes: (actual: String, reference: String)? = nil) {
        self.reference = reference
        self.actual = actual
        self.pixels = pixels
        self.perceptual = perceptual
        self.sizes = sizes
    }

    public static func == (a: SnapshotMismatch, b: SnapshotMismatch) -> Bool {
        a.reference == b.reference && a.actual == b.actual && a.pixels == b.pixels && a.perceptual == b.perceptual
            && a.sizes?.actual == b.sizes?.actual && a.sizes?.reference == b.sizes?.reference
    }

    /// Each assertion's mismatch in a message, in order; a test's failures may be joined in one message.
    public static func parse(_ message: String) -> [SnapshotMismatch] {
        let ns = message as NSString
        func ranges(_ regex: NSRegularExpression) -> [NSTextCheckingResult] {
            regex.matches(in: message, range: NSRange(location: 0, length: ns.length))
        }
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
        }
        // An assertion's text runs from one image pair to the next: the numbers after a pair are its.
        var pairs: [(location: Int, reference: String, actual: String)] = ranges(defaultDiff).map {
            ($0.range.location, decoded(group($0, 1)!), decoded(group($0, 2)!))
        }
        if pairs.isEmpty {
            pairs = ranges(diffToolPair).compactMap { m in
                let paths = [group(m, 1) ?? group(m, 2), group(m, 3) ?? group(m, 4)].compactMap { $0 }
                guard paths.count == 2, let reference = paths.first(where: { $0.contains("/__Snapshots__/") }),
                      let actual = paths.first(where: { $0 != reference }) else { return nil }
                return (m.range.location, reference, actual)
            }
        }
        let starts = pairs.isEmpty ? [0] : [0] + pairs.dropFirst().map(\.location)
        return starts.indices.map { i in
            let end = i + 1 < starts.count ? starts[i + 1] : ns.length
            let range = NSRange(location: starts[i], length: end - starts[i])
            var mismatch = SnapshotMismatch(reference: pairs.indices.contains(i) ? pairs[i].reference : nil,
                                            actual: pairs.indices.contains(i) ? pairs[i].actual : nil)
            for regex in [pixelPrecision, pixelPrecisionBefore1_12] {
                if let m = regex.firstMatch(in: message, range: range), let actual = Double(group(m, 1)!), let required = Double(group(m, 2)!) {
                    mismatch.pixels = Precision(actual: actual, required: required)
                }
            }
            for regex in [perceptualPrecision, perceptualPrecisionBefore1_12] {
                if let m = regex.firstMatch(in: message, range: range), let actual = Double(group(m, 1)!), let required = Double(group(m, 2)!) {
                    mismatch.perceptual = Precision(actual: actual, required: required)
                }
            }
            if let m = sizeMismatch.firstMatch(in: message, range: range) {
                mismatch.sizes = (group(m, 1)!, group(m, 2)!)
            }
            return mismatch
        }.filter { $0.reference != nil || $0.pixels != nil || $0.perceptual != nil || $0.sizes != nil }
    }

    /// The measurements, worded for a person: "0.65% of pixels differ, none may", "worst pixel matches 0.365,
    /// 0.98 required".
    public var metrics: [String] {
        var out: [String] = []
        if let sizes {
            out.append("Size \(Self.size(sizes.actual)), reference \(Self.size(sizes.reference))")
        }
        if let pixels {
            let differ = Self.percent(1 - pixels.actual), allowed = 1 - pixels.required
            out.append("\(differ) of pixels differ, " + (allowed <= 0 ? "none may" : "\(Self.percent(allowed)) may"))
        }
        if let perceptual {
            out.append("worst pixel matches \(Self.number(perceptual.actual)), \(Self.number(perceptual.required)) required")
        }
        return out
    }

    /// A failure message's first line that says something: swift-snapshot-testing opens with
    /// "Snapshot does not match reference." and puts the numbers further down, so those come first when
    /// there are some.
    public static func headline(of message: String) -> String {
        if let first = parse(message).first, let metric = first.metrics.first {
            return metric.prefix(1).uppercased() + metric.dropFirst()
        }
        return message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? message
    }

    // MARK: Patterns

    /// The default diff: `@−` then the reference's file URL, `@+` then the image taken.
    private static let defaultDiff = try! NSRegularExpression(
        pattern: #"@\x{2212}\s*\n\s*"file://([^"]+)"\s*\n\s*@\+\s*\n\s*"file://([^"]+)""#
    )
    /// A diff tool's command line with two absolute PNG paths, quoted or not: `ksdiff "/a.png" "/b.png"`.
    private static let diffToolPair = try! NSRegularExpression(
        pattern: #"(?:"(/[^"\n]+\.png)"|(?<![^\s])(/[^\s"]+\.png))[ \t]+(?:"(/[^"\n]+\.png)"|(/[^\s"]+\.png)(?![^\s]))"#
    )
    /// swift-snapshot-testing 1.12 and later.
    private static let pixelPrecision = try! NSRegularExpression(
        pattern: #"percentage of pixels that match ([0-9.]+) is less than required ([0-9.]+)"#
    )
    private static let perceptualPrecision = try! NSRegularExpression(
        pattern: #"lowest perceptual color precision ([0-9.]+) is less than required ([0-9.]+)"#
    )
    /// Before 1.12.
    private static let pixelPrecisionBefore1_12 = try! NSRegularExpression(
        pattern: #"Actual image precision ([0-9.]+) is less than required ([0-9.]+)"#
    )
    private static let perceptualPrecisionBefore1_12 = try! NSRegularExpression(
        pattern: #"Actual perceptual precision ([0-9.]+) is less than required ([0-9.]+)"#
    )
    /// `Newly-taken snapshot@(390.0, 844.0) does not match reference@(390.0, 800.0).`
    private static let sizeMismatch = try! NSRegularExpression(
        pattern: #"snapshot@(\([0-9., ]+\)) does not match reference@(\([0-9., ]+\))"#
    )

    private static func decoded(_ url: String) -> String { url.removingPercentEncoding ?? url }

    /// `(390.0, 844.0)` → `390×844`.
    static func size(_ text: String) -> String {
        let numbers = text.trimmingCharacters(in: CharacterSet(charactersIn: "() ")).split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return numbers.count == 2 ? "\(number(numbers[0]))×\(number(numbers[1]))" : text
    }

    /// `0.0065` → `0.65%`.
    static func percent(_ share: Double) -> String { number((share * 100 * 100).rounded() / 100) + "%" }

    /// Without trailing zeros: `0.98`, `390`.
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)).locale(Locale(identifier: "en_US_POSIX")).grouping(.never))
    }
}
