import Foundation

public enum SnapshotKitPaths {
    /// Settings and state directory. `SNAPSHOTKIT_HOME` overrides it (tests, scripts).
    public static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["SNAPSHOTKIT_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SnapshotKit", isDirectory: true)
    }
}

extension URL {
    /// Resolves symlinks such as /tmp → /private/tmp so paths from xcodebuild compare equal.
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
