import Foundation

/// The images swift-snapshot-testing attaches when a snapshot does not match:
/// the stored reference, the newly taken image, and a difference image.
public struct SnapshotFailureImages: Hashable, Codable, Sendable, Identifiable {
    public var testIdentifier: String
    public var repetition: Int
    /// Index of the assertion within the test (the `_0_` in `failure_0_<uuid>.png`).
    public var index: Int
    public var reference: URL?
    public var failure: URL?
    public var difference: URL?
    public var device: String?
    /// Repository-relative path of the reference PNG, when it could be read from the failure message.
    public var referencePath: String?

    public init(testIdentifier: String, repetition: Int, index: Int, reference: URL? = nil, failure: URL? = nil,
                difference: URL? = nil, device: String? = nil, referencePath: String? = nil) {
        self.testIdentifier = testIdentifier
        self.repetition = repetition
        self.index = index
        self.reference = reference
        self.failure = failure
        self.difference = difference
        self.device = device
        self.referencePath = referencePath
    }

    public var id: String { "\(testIdentifier)#\(repetition)#\(index)" }
}

public enum FailureAttachments {
    struct ManifestEntry: Decodable {
        struct Attachment: Decodable {
            var exportedFileName: String
            var suggestedHumanReadableName: String?
            var repetitionNumber: Int?
            var deviceName: String?
        }
        var testIdentifier: String
        var attachments: [Attachment]
    }

    /// Exports attachments from a result bundle into `directory` and groups snapshot images.
    ///
    /// `directory` may be a folder the user named, with other files in it: only the files of an
    /// earlier export (the ones its manifest lists) are replaced.
    public static func export(resultBundle: URL, to directory: URL, developerDir: String?) throws -> [SnapshotFailureImages] {
        removePreviousExport(in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try Shell.run(
            ["xcrun", "xcresulttool", "export", "attachments", "--path", resultBundle.path, "--output-path", directory.path],
            environment: developerDir.map { ["DEVELOPER_DIR": $0] }
        )
        guard result.succeeded else {
            throw CommandError(command: ["xcresulttool", "export", "attachments"], result: result)
        }
        let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try parse(manifest: manifest, directory: directory)
    }

    static func removePreviousExport(in directory: URL) {
        let manifest = directory.appendingPathComponent("manifest.json")
        guard let data = FileManager.default.contents(atPath: manifest.path),
              let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data) else { return }
        for attachment in entries.flatMap(\.attachments) {
            // Only names directly in the folder: a manifest is no licence to delete anything else.
            let name = (attachment.exportedFileName as NSString).lastPathComponent
            guard name == attachment.exportedFileName, !name.hasPrefix(".") else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: manifest)
    }

    public static func parse(manifest: Data, directory: URL) throws -> [SnapshotFailureImages] {
        let entries = try JSONDecoder().decode([ManifestEntry].self, from: manifest)
        var grouped: [String: SnapshotFailureImages] = [:]
        for entry in entries {
            for attachment in entry.attachments {
                guard let name = attachment.suggestedHumanReadableName,
                      let (role, index) = role(of: name) else { continue }
                let repetition = attachment.repetitionNumber ?? 1
                let key = "\(entry.testIdentifier)#\(repetition)#\(index)"
                var images = grouped[key] ?? SnapshotFailureImages(
                    testIdentifier: entry.testIdentifier, repetition: repetition, index: index, device: attachment.deviceName
                )
                let url = directory.appendingPathComponent(attachment.exportedFileName)
                switch role {
                case "reference": images.reference = url
                case "failure": images.failure = url
                case "difference": images.difference = url
                default: break
                }
                grouped[key] = images
            }
        }
        return grouped.values.sorted { ($0.testIdentifier, $0.repetition, $0.index) < ($1.testIdentifier, $1.repetition, $1.index) }
    }

    /// `failure_0_<uuid>.png` → ("failure", 0). Also accepts plain `failure.png`.
    static func role(of name: String) -> (String, Int)? {
        guard name.hasSuffix(".png") else { return nil }
        let base = String(name.dropLast(4))
        for role in ["reference", "failure", "difference"] where base == role || base.hasPrefix(role + "_") {
            let rest = base.dropFirst(role.count + 1)
            let index = Int(rest.split(separator: "_").first ?? "") ?? 0
            return (role, index)
        }
        return nil
    }

    /// Reference snapshot paths from a swift-snapshot-testing failure message, made relative to
    /// `repository`. The message names the reference with the default diff tool
    /// (`@−\n"file:///…/__Snapshots__/Suite/test.1.png"`), or a configured diff tool's command line
    /// (`snapkit open "/…/__Snapshots__/Suite/test.1.png" "/…/tmp/…/test.1.png"`).
    public static func referencePaths(in message: String, repository: URL) -> [String] {
        let ns = message as NSString
        let all = NSRange(location: 0, length: ns.length)
        var references = defaultDiffReference.matches(in: message, range: all).map { m in
            let url = ns.substring(with: m.range(at: 1))
            return url.removingPercentEncoding ?? url
        }
        if references.isEmpty {
            // The failed image is written outside `__Snapshots__`, so every such path is a reference.
            references = diffToolReference.matches(in: message, range: all).map { m in
                ns.substring(with: m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2))
            }
        }
        let root = URL.canonicalPath(repository.path)
        return references.compactMap { raw in
            let path = URL.canonicalPath(raw)
            if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
            // Paths from another machine (CI): keep the part from the first __Snapshots__ ancestor's parent.
            if let range = raw.range(of: "/__Snapshots__/") {
                let before = raw[..<range.lowerBound]
                return before.split(separator: "/").last.map { "…/\($0)/__Snapshots__/" + raw[range.upperBound...] }
            }
            return nil
        }
    }

    /// `@−` + reference path for a mismatch; `open "file://…"` for a newly recorded reference.
    private static let defaultDiffReference = try! NSRegularExpression(
        pattern: #"(?:@\x{2212}\s*\n\s*|No reference was found on disk[^\n]*\n\s*\n?\s*open )"file://([^"]+)""#
    )
    /// An absolute path to a PNG under `__Snapshots__`, quoted (`"…"`) or, as a diff tool given as
    /// a plain string leaves it, bare.
    private static let diffToolReference = try! NSRegularExpression(
        pattern: #""(/[^"\n]*/__Snapshots__/[^"\n]*\.png)"|(?<![^\s])(/[^\s"]*/__Snapshots__/[^\s"]*\.png)(?![^\s])"#
    )

    /// swift-snapshot-testing's message for a test without a reference: it records one and fails
    /// once, so the next run passes. Not a mismatch.
    public static func isNewReference(_ message: String) -> Bool {
        message.contains("No reference was found on disk")
    }
}
