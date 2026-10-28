import Foundation

/// What Xcode's editor extension asks of SnapshotKit for the test at the cursor: show its snapshots
/// (or its failure in the last run), or re-record it.
///
/// It travels as `snapshotkit://test?action=show&suite=<type>&function=<name>`, without `function`
/// for a whole suite. The extension can't tell which project the file is in; the app asks Xcode.
public struct TestRequest: Hashable, Sendable {
    public enum Action: String, Sendable {
        case show
        case rerecord
    }

    public var action: Action
    public var test: SourceTest

    public init(_ action: Action, _ test: SourceTest) {
        self.action = action
        self.test = test
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = CompareRequest.scheme
        components.host = "test"
        components.queryItems = [URLQueryItem(name: "action", value: action.rawValue), URLQueryItem(name: "suite", value: test.suite)]
            + (test.function.map { [URLQueryItem(name: "function", value: $0)] } ?? [])
        return components.url!
    }

    /// The request a `snapshotkit://test` URL carries; nil for any other URL.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == CompareRequest.scheme, url.host?.lowercased() == "test",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let action = items.first(where: { $0.name == "action" })?.value.flatMap(Action.init(rawValue:)),
              let suite = items.first(where: { $0.name == "suite" })?.value, !suite.isEmpty
        else { return nil }
        let function = items.first(where: { $0.name == "function" })?.value
        self.init(action, SourceTest(suite: suite, function: function?.isEmpty == false ? function : nil))
    }
}
