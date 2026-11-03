import Foundation

/// A test run made in Xcode (⌘U, a test's diamond), as Xcode keeps it under DerivedData.
public struct XcodeTestRun: Equatable, Sendable {
    public var resultBundle: URL
    /// What Xcode calls it in the Report navigator: "Test ShopApp".
    public var title: String
    public var finished: Date
}

/// Finds the test runs Xcode made of a repository's tests. Each workspace or package Xcode builds has
/// a folder in DerivedData whose `info.plist` names it (`WorkspacePath`); the folder's `Logs/Test`
/// holds a result bundle per run, which `LogStoreManifest.plist` lists once the run has finished.
/// Runs of `xcodebuild -resultBundlePath` (SnapshotKit's own, `snapkit`'s) aren't listed there.
public enum XcodeTestRuns {
    /// Where Xcode keeps derived data: the folder chosen in Xcode's Locations settings, or the default.
    public static var derivedData: URL {
        if let custom = UserDefaults(suiteName: "com.apple.dt.Xcode")?.string(forKey: "IDECustomDerivedDataLocation"),
           custom.hasPrefix("/") {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    }

    /// Whether a changed path is a list of finished test runs: the one change that says a run ended.
    public static func isRunList(_ path: String) -> Bool {
        path.hasSuffix("/Logs/Test/LogStoreManifest.plist")
    }

    /// The DerivedData folders of the workspaces and packages inside `repository` (the repository
    /// itself as a package, a project in a subfolder).
    public static func folders(for repository: URL, in derivedData: URL) -> [URL] {
        let root = URL.canonicalPath(repository.path)
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return entries.filter { folder in
            guard let data = fm.contents(atPath: folder.appendingPathComponent("info.plist").path),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let workspace = info["WorkspacePath"] as? String else { return false }
            let path = URL.canonicalPath(workspace)
            return path == root || path.hasPrefix(root + "/")
        }
    }

    /// The finished runs in one DerivedData folder, oldest first.
    public static func runs(in folder: URL) -> [XcodeTestRun] {
        let logs = folder.appendingPathComponent("Logs/Test", isDirectory: true)
        guard let data = FileManager.default.contents(atPath: logs.appendingPathComponent("LogStoreManifest.plist").path),
              let manifest = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entries = manifest["logs"] as? [String: [String: Any]] else { return [] }
        return entries.values.compactMap { entry -> XcodeTestRun? in
            guard let file = entry["fileName"] as? String, file.hasSuffix(".xcresult"),
                  let stopped = entry["timeStoppedRecording"] as? Double else { return nil }
            let bundle = logs.appendingPathComponent(file, isDirectory: true)
            guard FileManager.default.fileExists(atPath: bundle.path) else { return nil }
            return XcodeTestRun(resultBundle: bundle, title: entry["title"] as? String ?? file,
                                finished: Date(timeIntervalSinceReferenceDate: stopped))
        }
        .sorted { $0.finished < $1.finished }
    }

    /// The repository's most recent run in Xcode, if it finished after `date`.
    public static func latest(for repository: URL, in derivedData: URL = derivedData, after date: Date = .distantPast) -> XcodeTestRun? {
        folders(for: repository, in: derivedData).flatMap(runs(in:)).filter { $0.finished > date }.max { $0.finished < $1.finished }
    }
}

extension XcodeTestRun {
    /// The run's results, as a run of SnapshotKit's own would report them.
    public func result(developerDir: String?) throws -> TestRunResult {
        let summary = try XCResultParser.load(resultBundle: resultBundle, developerDir: developerDir)
        return TestRunResult(commandLine: title, exitStatus: summary.failed > 0 ? 1 : 0, cancelled: false, resultBundle: resultBundle,
                             summary: summary, passed: summary.passed, failed: summary.failed, skipped: summary.skipped,
                             buildErrors: [], host: "Xcode")
    }
}
