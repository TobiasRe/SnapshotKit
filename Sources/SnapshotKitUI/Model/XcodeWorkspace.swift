import AppKit

/// What Xcode has open, for its editor extension: the extension sees the file's text, not where the
/// file is.
enum XcodeWorkspace {
    /// The project, workspace or package in Xcode's front window. Asked by Apple event, so the first
    /// time macOS asks whether SnapshotKit may control Xcode; nil when it may not, or Xcode isn't running.
    static func frontmost() async -> URL? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty else { return nil }
        return await Task.detached {
            var error: NSDictionary?
            let script = NSAppleScript(source: #"tell application id "com.apple.dt.Xcode" to get path of active workspace document"#)
            guard let path = script?.executeAndReturnError(&error).stringValue, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }.value
    }
}
