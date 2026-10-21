import Foundation
import Testing
@testable import SnapshotKitCore

/// Files written by earlier versions, as they wrote them (see the history of ProjectStore.swift,
/// RunHistory.swift, ProjectContext.swift and RecordSession.swift), still read after an update.
@Suite struct OlderFilesTests {
    /// The first settings file: no `showMenuBarItem`, and paths as they were opened, before paths
    /// were made canonical (`/private/var/…` is `/var/…`).
    @Test func settingsFromTheFirstVersion() throws {
        let folder = testTemp("projects")
        for name in ["app", "lib"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let old = "/private" + folder.path
        let url = testTemp("settings").appendingPathExtension("json")
        try Data("""
            {
              "discovered" : [
                "\(old)/app",
                "\(old)/lib"
              ],
              "flakeIterations" : 3,
              "lastProject" : "\(old)/app",
              "pinned" : [
                "\(old)/lib"
              ],
              "projectSettings" : {
                "\(old)/app" : {
                  "baseBranch" : "trunk",
                  "module" : "AppSnapshotTests"
                }
              },
              "recents" : [
                "\(old)/app"
              ],
              "scanRoots" : [
                "\(old)"
              ],
              "verifyAfterRecord" : false
            }
            """.utf8).write(to: url)

        let app = folder.appendingPathComponent("app").path, lib = folder.appendingPathComponent("lib").path
        let store = ProjectStore(url: url)
        #expect(store.allProjects.map(\.path) == [lib, app])
        #expect(store.isPinned(Project(path: lib)))
        #expect(store.settings(for: Project(path: app)) == ProjectSettings(baseBranch: "trunk", module: "AppSnapshotTests"))
        var expected = AppSettings()
        expected.scanRoots = [folder.path]
        expected.discovered = [app, lib]
        expected.pinned = [lib]
        expected.recents = [app]
        expected.projectSettings = [app: ProjectSettings(baseBranch: "trunk", module: "AppSnapshotTests")]
        expected.lastProject = app
        expected.flakeIterations = 3
        expected.verifyAfterRecord = false
        #expect(store.settings == expected)

        // The first write keeps all of it, in the current form.
        store.markOpened(Project(path: lib))
        expected.recents = [lib, app]
        expected.lastProject = lib
        #expect(ProjectStore(url: url).settings == expected)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(written["showMenuBarItem"] as? Bool == false)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("/private"))
    }

    /// An older version could save one project under two spellings of its path. The settings saved
    /// under the canonical one, which this version writes, win; not whichever the dictionary
    /// happened to list first (that changed from launch to launch).
    @Test func settingsSavedUnderTwoSpellingsOfAPathKeepTheCanonicalOnes() throws {
        let app = testTemp("app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let url = testTemp("settings").appendingPathExtension("json")
        for order in [["/private" + app.path, app.path], [app.path, "/private" + app.path]] {
            let entries = order.map { #""\#($0)": {"baseBranch": "\#($0 == app.path ? "current" : "old")"}"# }
            try Data(#"{"projectSettings": {\#(entries.joined(separator: ", "))}}"#.utf8).write(to: url)
            #expect(ProjectStore(url: url).settings.projectSettings == [app.path: ProjectSettings(baseBranch: "current")])
        }
    }

    /// The first `last-run.json`: no `suites`. A re-record's verification is still merged into it.
    @Test func lastRunFromTheFirstVersion() throws {
        let repo = try TempRepo()
        let url = try repo.git.gitDirectory().appendingPathComponent("snapshotkit/last-run.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {
              "attachmentsDirectory" : "/old/repo/.git/snapshotkit/results/A.attachments",
              "date" : "2026-05-01T10:42:00Z",
              "failed" : 1,
              "failingSuites" : [
                {
                  "bundle" : "AppTests",
                  "failureFiles" : [
                    "/old/repo/Tests/AppTests/CardTests.swift"
                  ],
                  "path" : [
                    "CardTests"
                  ],
                  "tests" : [
                    {
                      "duration" : 0.5,
                      "failureMessages" : [
                        "Snapshot does not match reference."
                      ],
                      "identifier" : "CardTests/card()",
                      "name" : "card()",
                      "outcome" : "failed",
                      "repetitions" : [
                        "failed"
                      ]
                    }
                  ]
                }
              ],
              "host" : "local",
              "passed" : 4,
              "resultBundle" : "/old/repo/.git/snapshotkit/results/A.xcresult"
            }
            """.utf8).write(to: url)

        let last = try #require(LastRun.load(repository: repo.url))
        #expect(last.date == Date(timeIntervalSince1970: 1_777_632_120))
        #expect((last.host, last.passed, last.failed) == ("local", 4, 1))
        #expect(last.resultBundle == "/old/repo/.git/snapshotkit/results/A.xcresult")
        #expect(last.suites == nil)
        let suite = try #require(last.failingSuites.first)
        #expect(suite.identifier == "AppTests/CardTests")
        #expect(suite.tests == [TestCaseResult(name: "card()", identifier: "CardTests/card()", outcome: .failed,
                                               failureMessages: ["Snapshot does not match reference."], duration: 0.5, repetitions: [.failed])])

        let verified = SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [
            TestCaseResult(name: "card()", identifier: "CardTests/card()", outcome: .passed, failureMessages: [], repetitions: [.passed]),
        ], failureFiles: [])
        LastRun.update(with: LastRunTests.run([verified], bundle: "verify"), partial: true, repository: repo.url)
        let merged = try #require(LastRun.load(repository: repo.url))
        #expect(merged.failingSuites.isEmpty && merged.failed == 0)
        #expect(merged.resultBundle == "/results/verify.xcresult")
    }

    /// A run history as the version that introduced it wrote it.
    @Test func runHistoryFromTheFirstVersion() throws {
        let history = RunHistory(repository: URL(fileURLWithPath: "/some/repo"), home: testTemp("history"))
        try FileManager.default.createDirectory(at: history.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            [
              {
                "branch" : "main",
                "commit" : "0123456789abcdef0123456789abcdef01234567",
                "date" : "2026-05-01T10:42:00Z",
                "dirty" : false,
                "failed" : 1,
                "host" : "ci-mac",
                "id" : "7C6B1F0E-3A0B-4C49-9D2C-0F6A5E1B2C3D",
                "kind" : "flakeCheck",
                "outcomes" : {
                  "AppTests/CardTests/card()" : [
                    "passed",
                    "failed",
                    "passed"
                  ]
                },
                "passed" : 0,
                "resultBundle" : "/results/A.xcresult",
                "skipped" : 0
              }
            ]
            """.utf8).write(to: history.url)

        var expected = RunRecord(id: UUID(uuidString: "7C6B1F0E-3A0B-4C49-9D2C-0F6A5E1B2C3D")!, date: Date(timeIntervalSince1970: 1_777_632_120),
                                 kind: .flakeCheck, host: "ci-mac", commit: "0123456789abcdef0123456789abcdef01234567", branch: "main",
                                 dirty: false, summary: nil, passed: 0, failed: 1, skipped: 0, resultBundle: "/results/A.xcresult")
        expected.outcomes = ["AppTests/CardTests/card()": [.passed, .failed, .passed]]
        #expect(history.load() == [expected])
        #expect(RunHistory.timeline(for: "AppTests/CardTests/card()", in: history.load()).map(\.result) == [.mixed])

        var next = expected
        next.id = UUID()
        next.resultBundle = "/results/B.xcresult"
        history.append(next)
        #expect(history.load() == [expected, next])
        #expect(!FileManager.default.fileExists(atPath: history.url.appendingPathExtension("corrupt").path))
    }

    /// The file is named after the repository's path: a different name would lose the history of
    /// every project. (FNV-1a of the canonical path, in base 36.)
    @Test func aRepositorysHistoryKeepsItsFileName() {
        let history = RunHistory(repository: URL(fileURLWithPath: "/Users/dev/code/Shop"), home: URL(fileURLWithPath: "/home"))
        #expect(history.url.path == "/home/history/code-Shop-2o6ba8pqrtvjj.json")
    }

    /// A record patch journaled by the first version and left behind by a crash is restored by
    /// this one: an update in between must not strand a patched test source.
    @Test func recordPatchJournalFromTheFirstVersion() throws {
        let repo = try TempRepo()
        let path = "Tests/AppTests/CardTests.swift"
        try repo.write(path, RecordSessionTests.suiteSource)
        try repo.commitAll("init")
        let patched = RecordSessionTests.suiteSource.replacingOccurrences(of: "record: .missing", with: "record: .all")
        try repo.write(path, patched)
        let journal: [String: Any] = [
            "createdAt": "2026-05-01T10:42:00Z",
            "files": [[
                "original": RecordSessionTests.suiteSource, "originalSnippet": "@Suite(.snapshots(record: .missing))",
                "path": path, "patched": patched, "patchedSnippet": "@Suite(.snapshots(record: .all))", "suite": "CardTests",
            ]],
            "processIdentifier": 999_999,
            "repository": repo.url.path,
            "version": 1,
        ]
        let url = try RecordSession.journalURL(for: repo.url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: journal, options: [.prettyPrinted, .sortedKeys]).write(to: url)

        let report = try #require(try RecordSession.restoreLeftover(repository: repo.url))
        #expect(report.files.map(\.outcome) == [.restored])
        #expect(try repo.read(path) == RecordSessionTests.suiteSource)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite struct StateFileTests {
    struct Value: Codable, Equatable { var name: String }

    @Test func roundTripsAndCreatesItsFolder() throws {
        let url = testTemp("state").appendingPathComponent("deep/folder/value.json")
        StateFile.write(Value(name: "größe"), to: url)
        #expect(StateFile.read(Value.self, from: url) == Value(name: "größe"))
        // Written atomically: nothing but the file is left in its folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["value.json"])
    }

    @Test func aMissingFileIsNilAndNoCopyIsMade() {
        let url = testTemp("state").appendingPathExtension("json")
        #expect(StateFile.read(Value.self, from: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
    }

    /// The copy replaces an older one, and the file itself is left as it was until it is written.
    @Test func anUnreadableFileIsCopiedAsideAndLeftAlone() throws {
        let url = testTemp("state").appendingPathExtension("json")
        try Data("old garbage".utf8).write(to: url.appendingPathExtension("corrupt"))
        try Data(#"{"name": 42}"#.utf8).write(to: url)
        #expect(StateFile.read(Value.self, from: url) == nil)
        #expect(try String(contentsOf: url.appendingPathExtension("corrupt"), encoding: .utf8) == #"{"name": 42}"#)
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"name": 42}"#)
    }
}

@Suite struct ProjectStorePersistenceTests {
    func makeStore() -> ProjectStore { ProjectStore(url: testTemp("settings").appendingPathExtension("json")) }

    @Test func removingAProjectForgetsItEverywhere() {
        let store = makeStore()
        let a = Project(path: "/repos/a"), b = Project(path: "/repos/b")
        store.markOpened(a)
        store.markOpened(b)
        store.togglePin(a)
        store.remove(a)
        let reloaded = ProjectStore(url: store.url).settings
        #expect(reloaded.discovered == [b.path] && reloaded.recents == [b.path] && reloaded.pinned.isEmpty)
        #expect(reloaded.lastProject == b.path)
        store.remove(b)
        #expect(ProjectStore(url: store.url).settings.lastProject == nil)
    }

    /// A rescan only adds to what was discovered: a project no scan folder holds stays listed,
    /// pinned, recent or neither.
    @Test func rescanKeepsPinnedAndRecentProjects() throws {
        let store = makeStore()
        let root = testTemp("scan")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store.update { $0.discovered = ["/repos/stale"] }
        store.markOpened(Project(path: "/repos/recent"))
        store.togglePin(Project(path: "/repos/pinned"))
        store.addScanRoot(root.path)
        store.addScanRoot(root.path)
        #expect(store.rescan().isEmpty)
        let reloaded = ProjectStore(url: store.url).settings
        #expect(reloaded.discovered == ["/repos/pinned", "/repos/recent", "/repos/stale"])
        #expect(reloaded.scanRoots == [root.path])
        store.removeScanRoot(root.path)
        #expect(ProjectStore(url: store.url).settings.scanRoots.isEmpty)
    }
}
