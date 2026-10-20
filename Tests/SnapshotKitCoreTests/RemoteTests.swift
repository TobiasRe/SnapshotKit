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

        let remote = testTemp("remote").path
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
        let remote = testTemp("remote").path
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

    @Test func sshCommandShape() throws {
        let ssh = try SSHTransport(host: "ci-mac")
        let (exe, args) = ssh.command(for: "echo 'hi'", interactive: true)
        #expect(exe == "ssh")
        #expect(args.contains("-tt"))
        #expect(args.contains("BatchMode=yes"))
        #expect(args.suffix(3) == ["--", "ci-mac", #"/bin/bash -lc 'echo '\''hi'\'''"#])
        #expect(try ssh.rsyncLocation("/x") == "ci-mac:/x")
    }

    @Test func refusesHostsSshWouldReadAsOptions() throws {
        for host in ["-oProxyCommand=touch /tmp/pwned", "ci mac", "ci\tmac", "ci\u{7}", ""] {
            #expect(throws: RemoteError.invalidHost(host)) { try SSHTransport(host: host) }
        }
        var config = SnapshotConfig()
        config.remoteHost = "-oProxyCommand=x"
        #expect(throws: RemoteError.self) { try config.remoteTransport() }
        #expect(try SSHTransport(host: "ci@mac-1.local").label == "ci@mac-1.local")
    }

    @Test func refusesRemotePathsTheRemoteShellWouldSplit() throws {
        let ssh = try SSHTransport(host: "ci")
        #expect(throws: RemoteError.unsafeRemotePath(host: "ci", path: "/Users/ci/My App")) { try ssh.rsyncLocation("/Users/ci/My App") }
        // The default folder never needs quoting, whatever the repository is called.
        let runner = RemoteRunner(repository: URL(fileURLWithPath: "/repos/My Äpp (2)"), config: SnapshotConfig(), transport: ssh)
        let dir = runner.remoteDirectory(home: "/Users/ci")
        #expect(try ssh.rsyncLocation(dir) == "ci:" + dir)
        #expect(dir.hasPrefix("/Users/ci/.snapshotkit/workspaces/My-"))
    }

    @Test func onlySshsOwnFailureMeansUnreachable() throws {
        let unreachable = RemoteRunner(repository: URL(fileURLWithPath: "/r"), config: SnapshotConfig(), transport: FailingTransport(status: 255))
        #expect(throws: RemoteError.unreachable(host: "fake", output: "boom")) { try unreachable.preflight() }
        let failing = RemoteRunner(repository: URL(fileURLWithPath: "/r"), config: SnapshotConfig(), transport: FailingTransport(status: 1))
        #expect(throws: RemoteError.commandFailed(host: "fake", script: RemoteRunner.preflightScript, status: 1, output: "boom")) {
            try failing.preflight()
        }
    }

    @Test func syncsNonASCIIPaths() throws {
        let repo = try TempRepo()
        try repo.write("Tests/__Snapshots__/ÜbersichtTests/größe.1.png", "x")
        try repo.commitAll("init")
        try repo.write("Sources/Café.swift", "x")
        let runner = RemoteRunner(repository: repo.url, config: SnapshotConfig(), transport: LocalDirectoryTransport())
        #expect(try runner.filesToSync().sorted() == ["Sources/Café.swift", "Tests/__Snapshots__/ÜbersichtTests/größe.1.png"])
    }
}

/// A remote whose every command fails with `status`.
private struct FailingTransport: RemoteTransport {
    var status: Int32
    var label: String { "fake" }
    func command(for script: String, interactive: Bool) -> (executable: String, arguments: [String]) {
        ("/bin/sh", ["-c", "echo boom >&2; exit \(status)"])
    }
    func rsyncLocation(_ remotePath: String) -> String { remotePath }
    var rsyncArguments: [String] { [] }
}
