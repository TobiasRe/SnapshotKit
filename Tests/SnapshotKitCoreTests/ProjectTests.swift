import Foundation
import Testing
@testable import SnapshotKitCore

@Suite struct FuzzyMatcherTests {
    @Test func ranksWordStartsAndRejectsNonMatches() {
        let names = ["payments-ios", "SnapshotKit", "snap-old", "Settings"]
        #expect(FuzzyMatcher.rank(names, query: "snk", key: { $0 }) == ["SnapshotKit"])
        #expect(FuzzyMatcher.rank(names, query: "snap", key: { $0 }).first == "snap-old")
        // Letters typed together win over letters scattered across words.
        #expect(FuzzyMatcher.rank(["Refresh Changes", "Re-record Failing Tests"], query: "rec", key: { $0 }).first
                == "Re-record Failing Tests")
        #expect(FuzzyMatcher.score("xyz", in: "SnapshotKit") == nil)
        #expect(FuzzyMatcher.rank(names, query: "  ", key: { $0 }) == names)
    }
}

@Suite struct ProjectStoreTests {
    func makeStore() -> ProjectStore {
        ProjectStore(url: testTemp("settings").appendingPathExtension("json"))
    }

    @Test func pinsRecentsAndSettingsPersist() {
        let store = makeStore()
        let a = Project(path: "/repos/a"), b = Project(path: "/repos/b"), c = Project(path: "/repos/c")
        store.update { $0.discovered = [c.path, b.path, a.path] }
        store.markOpened(a)
        store.markOpened(b)
        store.togglePin(c)
        store.updateSettings(for: a) { $0.baseBranch = "trunk"; $0.remoteHost = "ci-mac" }

        let reloaded = ProjectStore(url: store.url)
        #expect(reloaded.allProjects.map(\.path) == [c.path, b.path, a.path])
        #expect(reloaded.settings.recents == [b.path, a.path])
        #expect(reloaded.isPinned(c))
        #expect(reloaded.settings(for: a) == ProjectSettings(baseBranch: "trunk", remoteHost: "ci-mac"))
        #expect(reloaded.settings.lastProject == b.path)

        reloaded.togglePin(c)
        #expect(!reloaded.isPinned(c))
    }

    @Test func twoStoresOnOneFileKeepEachOthersChanges() {
        let app = makeStore()
        let cli = ProjectStore(url: app.url)
        app.togglePin(Project(path: "/repos/a"))
        cli.markOpened(Project(path: "/repos/b"))
        app.update { $0.flakeIterations = 9 }

        let reloaded = ProjectStore(url: app.url)
        #expect(reloaded.settings.pinned == ["/repos/a"])
        #expect(reloaded.settings.recents == ["/repos/b"])
        #expect(reloaded.settings.flakeIterations == 9)
    }

    @Test func anUnreadableSettingsFileIsKept() throws {
        let url = testTemp("settings").appendingPathExtension("json")
        try Data(#"{"pinned": "not a list"}"#.utf8).write(to: url)
        let store = ProjectStore(url: url)
        store.togglePin(Project(path: "/repos/a"))
        #expect(ProjectStore(url: url).settings.pinned == ["/repos/a"])
        #expect(try String(contentsOf: url.appendingPathExtension("corrupt"), encoding: .utf8) == #"{"pinned": "not a list"}"#)
    }

    @Test func partialSettingsFileUsesDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"pinned": ["/a"]}"#.utf8))
        #expect(settings.pinned == ["/a"])
        #expect(settings.flakeIterations == 5)
        #expect(settings.verifyAfterRecord)
    }

    @Test func privateVarAliasesAreOneProject() throws {
        let url = testTemp("settings").appendingPathExtension("json")
        let name = "snapkit-alias-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "/private/var/tmp/\(name)", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: "/private/var/tmp/\(name)") }
        try Data(#"{"discovered": ["/private/var/tmp/\#(name)", "/var/tmp/\#(name)"], "recents": ["/private/var/tmp/\#(name)"]}"#.utf8).write(to: url)
        let store = ProjectStore(url: url)
        #expect(store.allProjects.count == 1)
    }

    @Test func nameMatchesBeatPathMatches() {
        let projects = [Project(path: "/tmp/payments/design-system"), Project(path: "/tmp/x/payments-ui")]
        #expect(FuzzyMatcher.rank(projects, query: "pay", primary: \.name, secondary: \.path).map(\.name)
                == ["payments-ui", "design-system"])
    }

    @Test func pathsMatchOnlyWhatWasTyped() {
        // p…a…y scattered over "snapkit-capture/projects/design-system" is no reason to list it.
        let projects = [Project(path: "/tmp/snapkit-capture/projects/design-system")]
        #expect(FuzzyMatcher.rank(projects, query: "pay", primary: \.name, secondary: \.path).isEmpty)
        #expect(FuzzyMatcher.rank(projects, query: "projects/des", primary: \.name, secondary: \.path).count == 1)
    }

    @Test func recentsAreCapped() {
        let store = makeStore()
        for i in 0..<(ProjectStore.maxRecents + 3) { store.markOpened(Project(path: "/r/\(i)")) }
        #expect(store.settings.recents.count == ProjectStore.maxRecents)
        #expect(store.settings.recents.first == "/r/\(ProjectStore.maxRecents + 2)")
    }

    @Test func scannerFindsReposWithSnapshots() throws {
        let root = testTemp("scan")
        func makeRepo(_ path: String, snapshots: Bool, override: Bool = false) throws {
            let dir = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Shell.output(["git", "init", "-q"], in: dir)
            if snapshots {
                let snap = dir.appendingPathComponent("Tests/__Snapshots__/A")
                try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
                try Data([1]).write(to: snap.appendingPathComponent("a.png"))
                try Shell.output(["git", "add", "-A"], in: dir)
            }
            if override { try "scheme: X\n".write(to: dir.appendingPathComponent(".snapshotkit.yml"), atomically: true, encoding: .utf8) }
        }
        try makeRepo("work/app", snapshots: true)
        try makeRepo("work/lib", snapshots: false)
        try makeRepo("work/configured", snapshots: false, override: true)
        try makeRepo("node_modules/pkg", snapshots: true)
        try makeRepo("a/b/c/d/e/deep", snapshots: true)
        try makeRepo("a/b/c/d/e/f/g/tooDeep", snapshots: true)

        // Recorded but not committed yet.
        try makeRepo("work/recorded", snapshots: false)
        let recorded = root.appendingPathComponent("work/recorded/Tests/__Snapshots__/A")
        try FileManager.default.createDirectory(at: recorded, withIntermediateDirectories: true)
        try Data([1]).write(to: recorded.appendingPathComponent("a.1.png"))

        // Depends on swift-snapshot-testing, nothing recorded yet.
        try makeRepo("work/fresh", snapshots: false)
        try #"{"pins":[{"identity":"swift-snapshot-testing"}]}"#.write(
            to: root.appendingPathComponent("work/fresh/Package.resolved"), atomically: true, encoding: .utf8)

        let report = ProjectScanner.scanReport(root: root)
        #expect(report.readable)
        let found = report.projects.map { ($0.path as NSString).lastPathComponent }
        #expect(found == ["deep", "app", "configured", "fresh", "recorded"])
    }
}

@Suite struct LastRunTests {
    @Test func keepsEverySuiteAndReadsOlderFiles() throws {
        let repo = try TempRepo()
        let passing = SuiteResult(bundle: "AppTests", path: ["ListTests"], tests: [
            TestCaseResult(name: "row()", identifier: "ListTests/row()", outcome: .passed, failureMessages: [], repetitions: [.passed]),
        ], failureFiles: [])
        let failing = SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [
            TestCaseResult(name: "card()", identifier: "CardTests/card()", outcome: .failed, failureMessages: ["x"], repetitions: [.failed]),
        ], failureFiles: [])
        let result = TestRunResult(commandLine: "xcodebuild test", exitStatus: 65, cancelled: false,
                                   resultBundle: URL(fileURLWithPath: "/tmp/r.xcresult"),
                                   summary: TestRunSummary(suites: [passing, failing]),
                                   passed: 1, failed: 1, skipped: 0, buildErrors: [])
        LastRun(result: result).save(repository: repo.url)
        let loaded = try #require(LastRun.load(repository: repo.url))
        #expect(loaded.suites?.map(\.identifier) == ["AppTests/ListTests", "AppTests/CardTests"])
        #expect(loaded.failingSuites.map(\.identifier) == ["AppTests/CardTests"])

        // Files from before `suites` existed still load.
        let url = repo.url.appendingPathComponent(".git/snapshotkit/last-run.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["suites"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(LastRun.load(repository: repo.url)?.suites == nil)
        #expect(LastRun.load(repository: repo.url)?.failed == 1)
    }
}

@Suite struct MenuBarSettingTests {
    @Test func offUnlessChosenAndKeptWhenSaved() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(AppSettings.self, from: Data("{}".utf8)).showMenuBarItem == false)
        var settings = try decoder.decode(AppSettings.self, from: Data(#"{"showMenuBarItem": true}"#.utf8))
        #expect(settings.showMenuBarItem)
        settings.showMenuBarItem = false
        let roundTrip = try decoder.decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.showMenuBarItem == false)
    }
}
