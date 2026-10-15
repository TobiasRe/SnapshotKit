import Foundation
import Testing
@testable import SnapshotKitCore

@Suite struct FuzzyMatcherTests {
    @Test func ranksWordStartsAndRejectsNonMatches() {
        let names = ["payments-ios", "SnapshotKit", "snap-old", "Settings"]
        #expect(FuzzyMatcher.rank(names, query: "snk", key: { $0 }) == ["SnapshotKit"])
        #expect(FuzzyMatcher.rank(names, query: "snap", key: { $0 }).first == "snap-old")
        #expect(FuzzyMatcher.score("xyz", in: "SnapshotKit") == nil)
        #expect(FuzzyMatcher.rank(names, query: "  ", key: { $0 }) == names)
    }
}

@Suite struct ProjectStoreTests {
    func makeStore() -> ProjectStore {
        ProjectStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-settings-\(UUID().uuidString).json"))
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

    @Test func partialSettingsFileUsesDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"pinned": ["/a"]}"#.utf8))
        #expect(settings.pinned == ["/a"])
        #expect(settings.flakeIterations == 5)
        #expect(settings.verifyAfterRecord)
    }

    @Test func privateVarAliasesAreOneProject() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-settings-\(UUID().uuidString).json")
        let name = "snapkit-alias-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "/private/var/tmp/\(name)", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: "/private/var/tmp/\(name)") }
        try Data(#"{"discovered": ["/private/var/tmp/\#(name)", "/var/tmp/\#(name)"], "recents": ["/private/var/tmp/\#(name)"]}"#.utf8).write(to: url)
        let store = ProjectStore(url: url)
        #expect(store.allProjects.count == 1)
    }

    @Test func nameMatchesBeatPathMatches() {
        let projects = [Project(path: "/tmp/snapkit-capture/projects/design-system"), Project(path: "/tmp/x/payments-ui")]
        #expect(FuzzyMatcher.rank(projects, query: "pay", primary: \.name, secondary: \.path).first?.name == "payments-ui")
    }

    @Test func recentsAreCapped() {
        let store = makeStore()
        for i in 0..<(ProjectStore.maxRecents + 3) { store.markOpened(Project(path: "/r/\(i)")) }
        #expect(store.settings.recents.count == ProjectStore.maxRecents)
        #expect(store.settings.recents.first == "/r/\(ProjectStore.maxRecents + 2)")
    }

    @Test func scannerFindsReposWithSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-scan-\(UUID().uuidString)").resolvingSymlinksInPath()
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

        let found = ProjectScanner.scan(root: root).map { ($0.path as NSString).lastPathComponent }
        #expect(found == ["app", "configured"])
    }
}
