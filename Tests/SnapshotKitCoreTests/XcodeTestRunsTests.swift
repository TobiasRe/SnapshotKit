import Foundation
import Testing
@testable import SnapshotKitCore

@Suite(.isolated) struct XcodeTestRunsTests {
    let derivedData = testTemp("DerivedData")

    /// A DerivedData folder as Xcode makes one for `workspace`, with the finished runs listed in its
    /// manifest (by name and finishing time) and their bundles. `unfinished` are listed without a
    /// finishing time, as a run still going; `gone` without their bundle.
    @discardableResult
    func xcodeFolder(_ name: String, for workspace: String, runs: [(String, Date)] = [], unfinished: [String] = [],
                     gone: [String] = []) throws -> URL {
        let folder = derivedData.appendingPathComponent(name, isDirectory: true)
        let logs = folder.appendingPathComponent("Logs/Test", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace], format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("info.plist"))
        var entries: [String: Any] = [:]
        for (file, finished) in runs {
            entries[UUID().uuidString] = ["fileName": file, "title": "Test App", "timeStoppedRecording": finished.timeIntervalSinceReferenceDate]
        }
        for file in unfinished { entries[UUID().uuidString] = ["fileName": file, "title": "Test App"] }
        for file in runs.map(\.0) + unfinished where !gone.contains(file) {
            try FileManager.default.createDirectory(at: logs.appendingPathComponent(file), withIntermediateDirectories: true)
        }
        try PropertyListSerialization.data(fromPropertyList: ["logs": entries], format: .xml, options: 0)
            .write(to: logs.appendingPathComponent("LogStoreManifest.plist"))
        return folder
    }

    /// The repository's own folders: itself as a package, a project in a subfolder; not another
    /// repository whose name starts the same, nor a folder without an `info.plist`.
    @Test func findsTheFoldersOfTheRepositorysWorkspaces() throws {
        let repo = testTemp("Shop")
        try xcodeFolder("Shop-a", for: repo.path)
        try xcodeFolder("ShopApp-b", for: repo.appendingPathComponent("Example/ShopApp.xcodeproj").path)
        try xcodeFolder("Shop-c", for: repo.path + "-other")
        try FileManager.default.createDirectory(at: derivedData.appendingPathComponent("ModuleCache.noindex"), withIntermediateDirectories: true)
        let found = XcodeTestRuns.folders(for: repo, in: derivedData).map(\.lastPathComponent).sorted()
        #expect(found == ["Shop-a", "ShopApp-b"])
    }

    /// The newest finished run of all the repository's folders; not one still going, nor one whose
    /// bundle Xcode has deleted; nothing if none finished after the date asked.
    @Test func theLatestRunIsTheNewestFinishedOne() throws {
        let repo = testTemp("Shop")
        let now = Date()
        try xcodeFolder("Shop-a", for: repo.path, runs: [("Test-1.xcresult", now - 60), ("Test-gone.xcresult", now - 5)],
                        unfinished: ["Test-going.xcresult"], gone: ["Test-gone.xcresult"])
        try xcodeFolder("ShopApp-b", for: repo.appendingPathComponent("Example/ShopApp.xcodeproj").path, runs: [("Test-2.xcresult", now - 30)])
        try xcodeFolder("Other-c", for: testTemp("Other").path, runs: [("Test-3.xcresult", now)])

        let latest = try #require(XcodeTestRuns.latest(for: repo, in: derivedData))
        #expect(latest.resultBundle.lastPathComponent == "Test-2.xcresult")
        #expect(latest.title == "Test App")
        #expect(abs(latest.finished.timeIntervalSince(now - 30)) < 0.001)
        #expect(XcodeTestRuns.latest(for: repo, in: derivedData, after: now - 30) == nil)
    }

    /// The manifest is what Xcode rewrites as a run ends; the bundles' own files aren't.
    @Test func theRunListIsTheManifest() {
        #expect(XcodeTestRuns.isRunList("/DD/Shop-a/Logs/Test/LogStoreManifest.plist"))
        #expect(!XcodeTestRuns.isRunList("/DD/Shop-a/Logs/Build/LogStoreManifest.plist"))
        #expect(!XcodeTestRuns.isRunList("/DD/Shop-a/Logs/Test/Test-1.xcresult/Info.plist"))
    }
}
