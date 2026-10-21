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

    /// A project added by hand and opened before the last ten, and one an earlier scan found that
    /// this one doesn't (its folder unreadable now, say), stay listed until removed.
    @Test func aRescanKeepsEveryProjectItDoesNotFind() throws {
        let store = makeStore()
        let root = testTemp("scan")
        let scanned = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: scanned.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data().write(to: scanned.appendingPathComponent(SnapshotConfig.overrideFileName))
        let added = Project(path: "/repos/added"), gone = Project(path: "/repos/found-before")
        store.markOpened(added)
        for i in 0..<ProjectStore.maxRecents { store.markOpened(Project(path: "/repos/opened-\(i)")) }
        store.update { $0.discovered.append(gone.path) }
        store.addScanRoot(root.path)

        store.rescan()
        let listed = store.allProjects.map(\.path)
        #expect(listed.contains(Project(path: scanned.path).path))
        #expect(listed.contains(added.path))
        #expect(listed.contains(gone.path))

        store.remove(added)
        store.rescan()
        #expect(!store.allProjects.map(\.path).contains(added.path))
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
        #expect(store.allProjects.map(\.path) == ["/var/tmp/\(name)"])
        #expect(store.settings.recents == ["/var/tmp/\(name)"])
    }

    /// A repository opened through a symlink (`~/code` → `/Volumes/Work/code`) is the one `git` and
    /// `snapkit` see: the same project, settings and history.
    @Test func aSymlinkedPathIsTheRepositoryItPointsTo() throws {
        let repo = try TempRepo()
        try repo.write("README.md", "x")
        try repo.commitAll("init")
        let link = testTemp("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo.url)

        #expect(Project(path: link.path) == Project(path: repo.url.path))
        let store = ProjectStore(url: testTemp("settings").appendingPathExtension("json"))
        store.updateSettings(for: Project(path: link.path)) { $0.baseBranch = "main" }
        let cliRepository = try #require(Git.repository(containing: link)).root
        #expect(store.settings(for: Project(path: cliRepository.path)).baseBranch == "main")
        #expect(RunHistory(repository: link).url == RunHistory(repository: cliRepository).url)
        #expect(try ProjectContext.load(repository: link).repository.path == cliRepository.path)
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
