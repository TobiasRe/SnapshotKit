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
    /// No reference was on disk, so the test recorded the image it took as the new one (at `actual`, under
    /// `__Snapshots__` on the machine that ran it) and failed: "No reference was found on disk.", or record mode.
    public var recorded: Bool

    public init(reference: String? = nil, actual: String? = nil, pixels: Precision? = nil, perceptual: Precision? = nil,
                sizes: (actual: String, reference: String)? = nil, recorded: Bool = false) {
        self.reference = reference
        self.actual = actual
        self.pixels = pixels
        self.perceptual = perceptual
        self.sizes = sizes
        self.recorded = recorded
    }

    public static func == (a: SnapshotMismatch, b: SnapshotMismatch) -> Bool {
        a.reference == b.reference && a.actual == b.actual && a.pixels == b.pixels && a.perceptual == b.perceptual
            && a.sizes?.actual == b.sizes?.actual && a.sizes?.reference == b.sizes?.reference && a.recorded == b.recorded
    }

    /// Whether the message says where the images are: without, there is nothing to fetch.
    public var namesImages: Bool { reference != nil || actual != nil }

    /// Whether the snapshot is an image, not text (`.txt`, a `dump`, JSON): a text snapshot's difference is in
    /// the message itself.
    public var isImage: Bool {
        guard let path = reference ?? actual else { return true }
        return Self.imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Each assertion's mismatch in a message, in order; a test's failures may be joined in one message.
    /// A message a JUnit writer kept as a string literal (`ksdiff \"/a.png\" \"/b.png\"`, `\n` for its line
    /// breaks) is read unescaped.
    public static func parse(_ message: String) -> [SnapshotMismatch] {
        let found = parseExactly(message)
        if found.contains(where: \.namesImages) { return found }
        let plain = unescaped(message)
        guard plain != message else { return found }
        let unescaped = parseExactly(plain)
        return unescaped.contains(where: \.namesImages) || found.isEmpty ? unescaped : found
    }

    /// The message as a person should read it: unescaped when it was kept as a string literal and only reads
    /// as a snapshot failure once unescaped; as is otherwise.
    public static func readable(_ message: String) -> String {
        if parseExactly(message).contains(where: \.namesImages) { return message }
        let plain = unescaped(message)
        return plain != message && parseExactly(plain).contains(where: \.namesImages) ? plain : message
    }

    /// Whether a failure message is swift-snapshot-testing's, whether or not it names its images.
    public static func isSnapshotFailure(_ message: String) -> Bool {
        let text = unescaped(message).lowercased()
        return ["does not match reference", "no reference was found on disk", "automatically recorded snapshot",
                "newly-taken snapshot", "/__snapshots__/"].contains { text.contains($0) }
            || !parse(message).isEmpty
    }

    /// The text with string-literal escapes undone, as Swift, JSON and XML write them: `\"`, `\n`, `\t`,
    /// `\\`, `\u{2212}`, `\u2212`, `&quot;`, `&#10;`. Up to three times, for a message escaped more than once.
    public static func unescaped(_ text: String) -> String {
        var current = text
        for _ in 0..<3 {
            let next = unescapeOnce(current)
            if next == current { break }
            current = next
        }
        return current
    }

    private static func unescapeOnce(_ text: String) -> String {
        guard text.contains("\\") || text.contains("&") else { return text }
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var i = 0
        func hex(_ from: Int, _ to: Int) -> Unicode.Scalar? {
            guard from <= to, to <= scalars.count else { return nil }
            return UInt32(String(String.UnicodeScalarView(scalars[from..<to])), radix: 16).flatMap(Unicode.Scalar.init)
        }
        while i < scalars.count {
            let c = scalars[i]
            if c == "\\", i + 1 < scalars.count {
                let n = scalars[i + 1]
                switch n {
                case "n": out.append("\n"); i += 2; continue
                case "t": out.append("\t"); i += 2; continue
                case "r": out.append("\r"); i += 2; continue
                case "\"", "'", "\\", "/": out.append(n); i += 2; continue
                case "u":
                    if i + 2 < scalars.count, scalars[i + 2] == "{", let close = scalars[(i + 3)...].firstIndex(of: "}"),
                       close - i <= 11, let scalar = hex(i + 3, close) {
                        out.append(scalar); i = close + 1; continue
                    }
                    if let scalar = hex(i + 2, i + 6), scalars[(i + 2)..<(i + 6)].allSatisfy(\.properties.isASCIIHexDigit) {
                        out.append(scalar); i += 6; continue
                    }
                default: break
                }
            } else if c == "&", let semicolon = scalars[i...].prefix(10).firstIndex(of: ";") {
                let entity = String(String.UnicodeScalarView(scalars[(i + 1)..<semicolon]))
                let named: [String: Unicode.Scalar] = ["quot": "\"", "apos": "'", "amp": "&", "lt": "<", "gt": ">"]
                var scalar = named[entity]
                if scalar == nil, entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
                } else if scalar == nil, entity.hasPrefix("#") {
                    scalar = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init)
                }
                if let scalar {
                    out.append(scalar); i = semicolon + 1; continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    private static func parseExactly(_ message: String) -> [SnapshotMismatch] {
        let ns = message as NSString
        func ranges(_ regex: NSRegularExpression) -> [NSTextCheckingResult] {
            regex.matches(in: message, range: NSRange(location: 0, length: ns.length))
        }
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
        }
        // An assertion's text runs from one image pair to the next: the numbers after a pair are its.
        func path(_ m: NSTextCheckingResult, scheme: Int, path: Int) -> String {
            group(m, scheme) == nil ? group(m, path)! : decoded(group(m, path)!)
        }
        var pairs: [(location: Int, reference: String?, actual: String, recorded: Bool)] = ranges(defaultDiff).map {
            ($0.range.location, path($0, scheme: 1, path: 2), path($0, scheme: 3, path: 4), false)
        }
        if pairs.isEmpty {
            pairs = ranges(diffToolPair).compactMap { m in
                let paths = [group(m, 1) ?? group(m, 2) ?? group(m, 3), group(m, 4) ?? group(m, 5) ?? group(m, 6)]
                    .compactMap { $0 }.map(decodedIfURL)
                guard paths.count == 2, paths[0] != paths[1] else { return nil }
                // Reference first, as swift-snapshot-testing passes them, unless only the second is under `__Snapshots__`.
                let swapped = !paths[0].contains("/__Snapshots__/") && paths[1].contains("/__Snapshots__/")
                return (m.range.location, swapped ? paths[1] : paths[0], swapped ? paths[0] : paths[1], false)
            }
        }
        if pairs.isEmpty {
            // No reference: the image taken became it, on the machine that ran the test.
            pairs = ranges(recordedSnapshot).map { ($0.range.location, nil, path($0, scheme: 1, path: 2), true) }
        }
        let starts = pairs.isEmpty ? [0] : [0] + pairs.dropFirst().map(\.location)
        return starts.indices.map { i in
            let end = i + 1 < starts.count ? starts[i + 1] : ns.length
            let range = NSRange(location: starts[i], length: end - starts[i])
            let pair = pairs.indices.contains(i) ? pairs[i] : nil
            var mismatch = SnapshotMismatch(reference: pair?.reference, actual: pair?.actual, recorded: pair?.recorded ?? false)
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
        }.filter { $0.namesImages || $0.pixels != nil || $0.perceptual != nil || $0.sizes != nil }
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

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "pdf"]

    /// The default diff: `@−` then the reference's file URL, `@+` then the image taken. Also with a plain hyphen,
    /// and with paths instead of URLs, as other writers put them.
    private static let defaultDiff = try! NSRegularExpression(
        pattern: #"@[\x{2212}\-]\s*\n\s*"(file://)?([^"\n]+)"\s*\n\s*@\+\s*\n\s*"(file://)?([^"\n]+)""#
    )
    /// A diff tool's command line with two absolute image paths or file URLs, in double quotes, single quotes or
    /// none: `ksdiff "/a.png" "/b.png"`, `compare file:///a.png file:///b.png`.
    private static let diffToolPair: NSRegularExpression = {
        func quoted(_ quote: String) -> String { #"\#(quote)((?:file://)?/[^\#(quote)\n]+\.(?:png|jpe?g|heic|tiff))\#(quote)"# }
        let bare = #"((?:file://)?/[^\s"']+\.(?:png|jpe?g|heic|tiff))"#
        return try! NSRegularExpression(
            pattern: #"(?:\#(quoted("\""))|\#(quoted("'"))|(?<![^\s])\#(bare))[ \t]+(?:\#(quoted("\""))|\#(quoted("'"))|\#(bare)(?![^\s]))"#,
            options: [.caseInsensitive]
        )
    }()
    /// `No reference was found on disk. Automatically recorded snapshot: …` (or `Record mode is on. …`), then
    /// `open "file:///…/__Snapshots__/…png"`.
    private static let recordedSnapshot = try! NSRegularExpression(
        pattern: #"Automatically recorded snapshot:[^\n]*\n(?:[^\n]*\n){0,3}?\s*open "(file://)?([^"\n]+)""#
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

    private static func decodedIfURL(_ path: String) -> String {
        path.hasPrefix("file://") ? decoded(String(path.dropFirst("file://".count))) : path
    }

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
