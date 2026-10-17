import Foundation

/// A reference image and the image a test produced instead, to compare in SnapshotKit.
///
/// It travels as `snapshotkit://compare?reference=<path>&actual=<path>`: `snapkit open` (the diff tool
/// for swift-snapshot-testing) opens that URL, and the app shows the pair in a compare window.
public struct CompareRequest: Hashable, Sendable {
    public static let scheme = "snapshotkit"

    public var reference: URL
    public var actual: URL

    public init(reference: URL, actual: URL) {
        self.reference = reference.standardizedFileURL
        self.actual = actual.standardizedFileURL
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "compare"
        components.queryItems = [URLQueryItem(name: "reference", value: reference.path),
                                 URLQueryItem(name: "actual", value: actual.path)]
        // `+` is a literal in a query value but a space to some decoders; spell it out.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// The request a `snapshotkit://compare` URL carries; nil for any other URL.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "compare",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let reference = items.first(where: { $0.name == "reference" })?.value, !reference.isEmpty,
              let actual = items.first(where: { $0.name == "actual" })?.value, !actual.isEmpty
        else { return nil }
        self.init(reference: URL(fileURLWithPath: reference), actual: URL(fileURLWithPath: actual))
    }

    /// The reference as the library names it: its path in its git repository, if it is in one.
    public var location: (repository: URL, path: String)? {
        guard let root = Git.repository(containing: reference.deletingLastPathComponent())?.root else { return nil }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let file = reference.resolvingSymlinksInPath().path
        guard file.hasPrefix(rootPath + "/") else { return nil }
        return (root, String(file.dropFirst(rootPath.count + 1)))
    }
}
