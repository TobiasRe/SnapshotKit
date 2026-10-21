import Foundation
import Testing
@testable import SnapshotKitCore

@Suite(.isolated) struct RemoteRunnerTests {
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

    @Test func syncsTheFilesOfSubmodules() throws {
        let library = try TempRepo()
        try library.write("Sources/Lib.swift", "lib")
        try library.commitAll("lib")
        let repo = try TempRepo()
        try repo.write("App.swift", "app")
        try repo.git.run(["-c", "protocol.file.allow=always", "submodule", "add", "-q", library.url.path, "Vendor/Lib"])
        try repo.commitAll("init")

        let runner = RemoteRunner(repository: repo.url, config: SnapshotConfig(), transport: LocalDirectoryTransport())
        #expect(try runner.filesToSync().sorted() == [".gitmodules", "App.swift", "Vendor/Lib/Sources/Lib.swift"])
        let remote = testTemp("remote").path
        try runner.sync(to: remote)
        #expect(FileManager.default.fileExists(atPath: remote + "/Vendor/Lib/Sources/Lib.swift"))
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

    @Test func downloadsWhatTheRecordRunWroteWhateverItIsCalled() throws {
        let repo = try TempRepo()
        try repo.write("README", "x")
        try repo.commitAll("init")
        let remote = testTemp("remote").path, state = remote + "/.snapshotkit"
        let fm = FileManager.default
        try fm.createDirectory(atPath: state, withIntermediateDirectories: true)
        fm.createFile(atPath: state + "/record-marker", contents: nil, attributes: [.modificationDate: Date(timeIntervalSinceNow: -60)])
        let recorded = "Tests/AppTests/__Snapshots__/ÜbersichtTests/größe 2.1.png"
        for path in [recorded, "DerivedData/SourcePackages/checkouts/Lib/__Snapshots__/LibTests/a.1.png"] {
            try fm.createDirectory(atPath: ((remote + "/" + path) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: remote + "/" + path, contents: Data("png".utf8))
        }

        let runner = RemoteRunner(repository: repo.url, config: SnapshotConfig(), transport: ShellSafePathsTransport())
        #expect(try runner.downloadRecordedSnapshots(dir: remote, stateDir: state) == [recorded])
        #expect(fm.contents(atPath: repo.url.appendingPathComponent(recorded).path) == Data("png".utf8))
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
        #expect(args == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-tt", "--", "ci-mac", #"/bin/bash -lc 'echo '\''hi'\'''"#])
        #expect(ssh.command(for: "true", interactive: false).arguments
                == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", "ci-mac", "/bin/bash -lc true"])
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

/// The record path end to end, without ssh or Xcode: a `FakeMac` stands in for both.
@Suite(.isolated) struct RemoteRecordTests {
    let suite = SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [], failureFiles: [])
    let source = "Tests/AppTests/CardTests.swift"
    let snapshot = "Tests/AppTests/__Snapshots__/CardTests/card.1.png"

    func makeRepo() throws -> TempRepo {
        let repo = try TempRepo()
        try repo.write(source, RecordSessionTests.suiteSource)
        // Not the size of the new one: rsync skips a file with the same size and modification second,
        // which a test (unlike a real recording) produces.
        try repo.write(snapshot, "the old reference")
        try repo.commitAll("init")
        return repo
    }

    func runner(_ repo: TempRepo, _ mac: FakeMac, scheme: String? = "App") -> RemoteRunner {
        var config = SnapshotConfig()
        config.scheme = scheme
        config.deviceName = "Example Phone"
        config.remoteDirectory = mac.checkout.path
        return RemoteRunner(repository: repo.url, config: config, transport: mac)
    }

    @Test func recordsRemotelyAndDownloadsTheNewReferences() async throws {
        let repo = try makeRepo()
        let mac = try FakeMac(xcodebuild: """
            grep -q 'record: .all' \(source) || { echo 'error: record mode is not on' >&2; exit 70; }
            printf new > \(snapshot)
            mkdir -p "$bundle" && cat > "$bundle/tests.json" <<'JSON'
            \(FakeMac.oneFailingTest)
            JSON
            echo '✘ Test card() failed after 0.1 seconds with 1 issue.'
            exit 65
            """)

        let result = try await runner(repo, mac).run(mode: .record(suites: [suite]))
        #expect(result.run.failed == 1)
        #expect(result.run.nothingTested == nil)
        #expect(result.downloadedSnapshots == [snapshot])
        #expect(try repo.read(snapshot) == "new")
        // Patched only on the remote copy, and put back there afterwards.
        #expect(try repo.read(source) == RecordSessionTests.suiteSource)
        #expect(try String(contentsOf: mac.checkout.appendingPathComponent(source), encoding: .utf8) == RecordSessionTests.suiteSource)
    }

    @Test func aBuildThatFailsRemotelyRecordsNothing() async throws {
        let repo = try makeRepo()
        let mac = try FakeMac(xcodebuild: """
            echo "$PWD/\(source):6:9: error: cannot find 'draw' in scope"
            exit 65
            """)

        let result = try await runner(repo, mac).run(mode: .record(suites: [suite]))
        #expect(result.run.nothingTested == "the build failed (CardTests.swift:6:9: cannot find 'draw' in scope)")
        #expect(result.downloadedSnapshots.isEmpty)
        #expect(try repo.read(snapshot) == "the old reference")
        #expect(try String(contentsOf: mac.checkout.appendingPathComponent(source), encoding: .utf8) == RecordSessionTests.suiteSource)
    }

    /// A cancelled record keeps what it wrote on the remote Mac: half a run's references aren't wanted.
    @Test func aCancelledRecordDownloadsNothing() async throws {
        let repo = try makeRepo()
        let mac = try FakeMac(xcodebuild: "printf new > \(snapshot)\nexec sleep 30")
        let runner = runner(repo, mac)
        let run = Task { try await runner.run(mode: .record(suites: [suite])) }
        let written = mac.checkout.appendingPathComponent(snapshot)
        for _ in 0..<200 where (try? String(contentsOf: written, encoding: .utf8)) != "new" {
            try await Task.sleep(for: .milliseconds(50))
        }
        // Cancelled once the run has written its reference, not before it got there.
        try #require(try String(contentsOf: written, encoding: .utf8) == "new")
        runner.cancel()

        let result = try await run.value
        #expect(result.run.cancelled)
        #expect(result.downloadedSnapshots.isEmpty)
        #expect(try repo.read(snapshot) == "the old reference")
        #expect(try String(contentsOf: written, encoding: .utf8) == "new")
        #expect(try String(contentsOf: mac.checkout.appendingPathComponent(source), encoding: .utf8) == RecordSessionTests.suiteSource)
    }

    /// Every way out after patching puts the remote sources back, also when the run never starts.
    @Test func restoresTheRemoteSourcesWhenTheRunFails() async throws {
        let repo = try makeRepo()
        let mac = try FakeMac(xcodebuild: "exit 0") // `-list` lists no scheme

        await #expect(throws: ConfigError.missingScheme) { try await runner(repo, mac, scheme: nil).run(mode: .record(suites: [suite])) }
        #expect(try String(contentsOf: mac.checkout.appendingPathComponent(source), encoding: .utf8) == RecordSessionTests.suiteSource)
    }
}

/// Runs and flakiness checks on a `FakeMac`: what comes back is as a local run's.
@Suite(.isolated) struct RemoteRunTests {
    let source = "Tests/AppTests/CardTests.swift"
    let snapshot = "Tests/AppTests/__Snapshots__/CardTests/card.1.png"

    func runner(_ repo: TempRepo, _ mac: FakeMac) -> RemoteRunner {
        var config = SnapshotConfig()
        config.scheme = "App"
        config.deviceName = "Example Phone"
        config.remoteDirectory = mac.checkout.path
        return RemoteRunner(repository: repo.url, config: config, transport: mac)
    }

    /// The failure's source file and reference are named by their remote paths: they come back as
    /// the local checkout's, and the failure image with them, next to the repository's own results.
    @Test func aRunsFailuresPointIntoTheLocalCheckout() async throws {
        let repo = try TempRepo()
        try repo.write(source, RecordSessionTests.suiteSource)
        try repo.commitAll("init")
        let mac = try FakeMac(xcodebuild: #"""
            mkdir -p "$bundle/attachments"
            cat > "$bundle/tests.json" <<JSON
            {"testNodes": [{"name": "AppTests", "nodeType": "Unit test bundle", "children": [
              {"name": "CardTests", "nodeType": "Test Suite", "children": [
                {"name": "card()", "nodeType": "Test Case", "nodeIdentifier": "CardTests/card()", "result": "Failed", "children": [
                  {"name": "Snapshot does not match reference.\n\n@−\n\"file://$PWD/\#(snapshot)\"", "nodeType": "Failure Message",
                   "sourceLocation": {"filePath": "$PWD/\#(source)", "lineNumber": 6}}]}]}]}]}
            JSON
            printf png > "$bundle/attachments/F.png"
            echo '[{"testIdentifier": "CardTests/card()", "attachments": [{"exportedFileName": "F.png", "suggestedHumanReadableName": "failure_0_A.png"}]}]' \
              > "$bundle/attachments/manifest.json"
            exit 65
            """#)

        let result = try await runner(repo, mac).run(mode: .run)
        let suite = try #require(result.run.summary?.suites.first)
        #expect(suite.failureFiles == [repo.url.path + "/" + source])
        #expect(suite.tests.flatMap(\.failureMessages).flatMap { FailureAttachments.referencePaths(in: $0, repository: repo.url) } == [snapshot])
        #expect(result.run.host == "fake-mac" && result.run.failed == 1)

        let images = try #require(result.attachmentsDirectory)
        #expect(images.deletingLastPathComponent().path == TestRunner.resultsDirectory(for: repo.url).path)
        #expect(images.pathExtension == "attachments")
        #expect(result.attachments.map(\.failure?.path) == [images.path + "/F.png"])
        #expect(FileManager.default.contents(atPath: images.path + "/F.png") == Data("png".utf8))
    }

    /// A flakiness check runs the tests the given number of times there, and reads each repetition.
    @Test func aFlakinessCheckRepeatsTheTests() async throws {
        let repo = try TempRepo()
        try repo.write(source, RecordSessionTests.suiteSource)
        try repo.commitAll("init")
        let mac = try FakeMac(xcodebuild: """
            printf '%s\\n' "${args[@]}" > .snapshotkit/arguments
            mkdir -p "$bundle" && echo '\(CLIFakeXcodeTests.flakyTest)' > "$bundle/tests.json"
            exit 65
            """)

        let result = try await runner(repo, mac).run(mode: .flakeCheck(iterations: 3), onlyTesting: ["AppTests/CardTests"])
        let arguments = try String(contentsOf: mac.checkout.appendingPathComponent(".snapshotkit/arguments"), encoding: .utf8)
        #expect(arguments.split(separator: "\n") == [
            "test", "-scheme", "App", "-destination", "platform=iOS Simulator,id=SIM-1", "-resultBundlePath", Substring(result.run.resultBundle.path),
            "-only-testing:AppTests/CardTests", "-collect-test-diagnostics", "never", "-test-iterations", "3", "-test-repetition-relaunch-enabled", "YES",
        ])
        let verdicts = Flakiness.classify(try #require(result.run.summary))
        #expect(verdicts.map { "\($0.label) \($0.passed)/\($0.failed) \($0.id)" } == ["Flaky 2/1 AppTests/CardTests/card()"])
        #expect(result.attachmentsDirectory == nil)
    }
}

/// A remote Mac in a local folder: scripts run with bash, with stand-ins for `xcodebuild` and
/// `xcrun` (simctl and xcresulttool) first on the PATH; the preflight reports one Xcode. A result
/// bundle's tests are its `tests.json`, and its attachments the folder `attachments` in it (with
/// its `manifest.json`), as `xcresulttool export` writes them.
struct FakeMac: RemoteTransport {
    let checkout: URL
    let bin: URL

    /// `xcodebuild` runs `script` in the remote checkout, with `$bundle` set to the result bundle
    /// path and `args` to its arguments.
    init(xcodebuild script: String) throws {
        checkout = testTemp("remote-checkout")
        bin = testTemp("fake-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Self.install("xcodebuild", """
            bundle=
            args=("$@")
            while [ $# -gt 0 ]; do [ "$1" = -resultBundlePath ] && bundle=$2; shift; done
            \(script)
            """, in: bin)
        try Self.install("xcrun", """
            case "$1 $2" in
              "simctl list") echo '{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-99-0": [{"name": "Example Phone", "udid": "SIM-1", "state": "Shutdown"}]}}' ;;
              "xcresulttool get") while [ "$1" != --path ]; do shift; done; cat "$2/tests.json" ;;
              "xcresulttool export") while [ "$1" != --path ]; do shift; done; bundle=$2
                while [ "$1" != --output-path ]; do shift; done; mkdir -p "$2"
                if [ -d "$bundle/attachments" ]; then cp -R "$bundle/attachments/." "$2/"; else echo '[]' > "$2/manifest.json"; fi ;;
              *) echo "unexpected: xcrun $*" >&2; exit 64 ;;
            esac
            """, in: bin)
    }

    private static func install(_ name: String, _ body: String, in bin: URL) throws {
        let url = bin.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    var label: String { "fake-mac" }

    func command(for script: String, interactive: Bool) -> (executable: String, arguments: [String]) {
        if script == RemoteRunner.preflightScript {
            return ("/bin/echo", ["HOME=/Users/ci\nSELECTED=/Applications/Xcode.app/Contents/Developer\nXCODE=/Applications/Xcode.app|99.0|99A1"])
        }
        return ("/usr/bin/env", ["PATH=\(bin.path):/usr/bin:/bin", "/bin/bash", "-c", script])
    }

    func rsyncLocation(_ remotePath: String) -> String { remotePath }
    var rsyncArguments: [String] { [] }

    /// `xcresulttool get test-results tests` for a run whose one test failed (as recording does).
    static let oneFailingTest = #"""
        {"testNodes": [{"name": "App", "nodeType": "Test Plan", "result": "Failed", "children": [
          {"name": "AppTests", "nodeType": "Unit test bundle", "result": "Failed", "children": [
            {"name": "CardTests", "nodeType": "Test Suite", "result": "Failed", "children": [
              {"name": "card()", "nodeType": "Test Case", "nodeIdentifier": "CardTests/card()", "result": "Failed", "children": [
                {"name": "Record mode is on. Automatically recorded snapshot.", "nodeType": "Failure Message"}]}]}]}]}]}
        """#
}

/// A local "remote" that, like ssh, refuses rsync paths the remote shell would split.
private struct ShellSafePathsTransport: RemoteTransport {
    var label: String { "strict" }
    func command(for script: String, interactive: Bool) -> (executable: String, arguments: [String]) {
        ("/bin/bash", ["-c", script])
    }
    func rsyncLocation(_ remotePath: String) throws -> String {
        guard Shell.quote(remotePath) == remotePath else { throw RemoteError.unsafeRemotePath(host: label, path: remotePath) }
        return remotePath
    }
    var rsyncArguments: [String] { [] }
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
