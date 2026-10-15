import Foundation
import Testing
@testable import SnapshotKitCore

@Suite struct RemoteRunnerTests {
    @Test func parsesPreflight() {
        let info = RemoteRunner.parsePreflight("""
        HOME=/Users/ci
        SELECTED=/Applications/Xcode-99.2.app/Contents/Developer
        XCODE=/Applications/Xcode-99.1.app|99.1|99A1
        XCODE=/Applications/Xcode-99.2.app|99.2|99B2
        XCODE=/Applications/Xcode-broken.app||
        """)
        #expect(info.home == "/Users/ci")
        #expect(info.xcodes.map(\.version) == ["99.2", "99.1"])
        #expect(info.selected?.version == "99.2")
    }

    @Test func remoteDirectoryDefaultsAndOverrides() {
        var config = SnapshotConfig()
        let runner = RemoteRunner(repository: URL(fileURLWithPath: "/repos/app"), config: config, transport: LocalDirectoryTransport())
        #expect(runner.remoteDirectory(home: "/Users/ci").hasPrefix("/Users/ci/.snapshotkit/workspaces/app-"))
        config.remoteDirectory = "~/work/app"
        let custom = RemoteRunner(repository: URL(fileURLWithPath: "/repos/app"), config: config, transport: LocalDirectoryTransport())
        #expect(custom.remoteDirectory(home: "/Users/ci") == "/Users/ci/work/app")
    }

    @Test func syncMirrorsWorkingTreeAndPrunesStaleFiles() throws {
        let repo = try TempRepo()
        try repo.write(".gitignore", "ignored.txt\n")
        try repo.write("Sources/A.swift", "a")
        try repo.write("ignored.txt", "secret")
        try repo.commitAll("init")
        try repo.write("Sources/Untracked.swift", "u")

        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-remote-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: remote + "/.build", withIntermediateDirectories: true)
        try "cache".write(toFile: remote + "/.build/keep", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: remote + "/Sources", withIntermediateDirectories: true)
        try "old".write(toFile: remote + "/Sources/Stale.swift", atomically: true, encoding: .utf8)

        let runner = RemoteRunner(repository: repo.url, config: SnapshotConfig(), transport: LocalDirectoryTransport())
        try runner.sync(to: remote)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: remote + "/Sources/A.swift"))
        #expect(fm.fileExists(atPath: remote + "/Sources/Untracked.swift"))
        #expect(!fm.fileExists(atPath: remote + "/ignored.txt"))
        #expect(!fm.fileExists(atPath: remote + "/Sources/Stale.swift"))
        #expect(fm.fileExists(atPath: remote + "/.build/keep"))
    }

    @Test func uploadsPatchedSourcesWithoutTouchingLocalFiles() throws {
        let repo = try TempRepo()
        try repo.write("Tests/AppTests/CardTests.swift", RecordSessionTests.suiteSource)
        try repo.commitAll("init")
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-remote-\(UUID().uuidString)").path
        let runner = RemoteRunner(repository: repo.url, config: SnapshotConfig(), transport: LocalDirectoryTransport())
        try runner.sync(to: remote)
        let suite = SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [], failureFiles: [])
        let paths = try runner.uploadPatchedSources(for: [suite], to: remote)
        #expect(paths == ["Tests/AppTests/CardTests.swift"])
        #expect(try String(contentsOfFile: remote + "/" + paths[0], encoding: .utf8).contains("record: .all"))
        #expect(try repo.read(paths[0]) == RecordSessionTests.suiteSource)
    }

    @Test func mapsRemotePathsToLocalCheckout() {
        let message = "@\u{2212}\n\"file:///private/var/x/remote/Tests/A/__Snapshots__/S/t.1.png\""
        #expect(RemoteRunner.mapPath(message, from: "/var/x/remote", to: "/repo") == "@\u{2212}\n\"file:///repo/Tests/A/__Snapshots__/S/t.1.png\"")
        #expect(RemoteRunner.mapPath("/Users/ci/w/a.swift", from: "/Users/ci/w", to: "/repo") == "/repo/a.swift")
    }

    @Test func sshCommandShape() {
        let ssh = SSHTransport(host: "ci-mac")
        let (exe, args) = ssh.command(for: "echo 'hi'", interactive: true)
        #expect(exe == "ssh")
        #expect(args.contains("-tt"))
        #expect(args.contains("BatchMode=yes"))
        #expect(args.last == #"/bin/bash -lc 'echo '\''hi'\'''"#)
        #expect(ssh.rsyncLocation("/x") == "ci-mac:/x")
    }
}
