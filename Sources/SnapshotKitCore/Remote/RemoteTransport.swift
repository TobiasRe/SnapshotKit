import Foundation

/// How SnapshotKit reaches a remote machine: run shell scripts there and copy files both ways.
public protocol RemoteTransport: Sendable {
    /// Shown in the UI and stored in run history ("ci-mac-1").
    var label: String { get }
    /// Executable and arguments that run `script` with bash on the remote machine.
    /// `interactive` allocates a TTY so that killing the local process stops the remote one.
    func command(for script: String, interactive: Bool) -> (executable: String, arguments: [String])
    /// rsync destination/source prefix for a remote path (`host:/path` or just `/path`).
    func rsyncLocation(_ remotePath: String) -> String
    /// Extra rsync arguments (e.g. `-e ssh …`).
    var rsyncArguments: [String] { get }
}

extension RemoteTransport {
    /// Runs a script remotely and returns its output; throws on non-zero exit.
    @discardableResult
    public func run(_ script: String, input: Data? = nil) throws -> String {
        let (exe, args) = command(for: script, interactive: false)
        let result = try Shell.run([exe] + args, input: input)
        guard result.succeeded else {
            throw RemoteError.commandFailed(host: label, script: script, output: (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    /// Copies the listed files (relative to `localRoot`) into `remoteDirectory`.
    public func upload(files: [String], from localRoot: URL, to remoteDirectory: String) throws {
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-files-\(UUID().uuidString).txt")
        try files.joined(separator: "\n").appending("\n").write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }
        try rsync(["-a", "--files-from=\(list.path)", localRoot.path + "/", rsyncLocation(remoteDirectory) + "/"])
    }

    /// Copies a remote file or directory to a local path.
    public func download(_ remotePath: String, to local: URL) throws {
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rsync(["-a", rsyncLocation(remotePath), local.path])
    }

    func rsync(_ args: [String]) throws {
        let result = try Shell.run(["rsync"] + rsyncArguments + args)
        guard result.succeeded else {
            throw RemoteError.syncFailed(host: label, output: (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// A real remote Mac reachable with `ssh` (key-based auth; SnapshotKit never asks for passwords).
public struct SSHTransport: RemoteTransport {
    public var host: String
    public var options: [String]

    public init(host: String, options: [String] = []) {
        self.host = host
        self.options = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15"] + options
    }

    public var label: String { host }

    public func command(for script: String, interactive: Bool) -> (executable: String, arguments: [String]) {
        ("ssh", options + (interactive ? ["-tt"] : []) + [host, "/bin/bash -lc " + Shell.quote(script)])
    }

    public func rsyncLocation(_ remotePath: String) -> String { "\(host):\(remotePath)" }

    public var rsyncArguments: [String] {
        ["-z", "-e", (["ssh"] + options).joined(separator: " ")]
    }
}

/// Treats a local directory as the "remote" machine. Useful for trying the remote workflow
/// against a second checkout, and for testing it without SSH.
public struct LocalDirectoryTransport: RemoteTransport {
    public init() {}
    public var label: String { "localhost" }

    public func command(for script: String, interactive: Bool) -> (executable: String, arguments: [String]) {
        ("/bin/bash", ["-c", script])
    }

    public func rsyncLocation(_ remotePath: String) -> String { remotePath }
    public var rsyncArguments: [String] { [] }
}

public enum RemoteError: Error, LocalizedError, Equatable {
    case notConfigured
    case commandFailed(host: String, script: String, output: String)
    case syncFailed(host: String, output: String)
    case unreachable(host: String, output: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No remote machine configured. Set `remoteHost:` in .snapshotkit.yml or in the project's settings."
        case let .commandFailed(host, _, output):
            "Command on \(host) failed: \(output)"
        case let .syncFailed(host, output):
            "Copying files to/from \(host) failed: \(output)"
        case let .unreachable(host, output):
            "Cannot reach \(host) over SSH (\(output)). Check that key-based login works: `ssh \(host) true`."
        }
    }
}

extension SnapshotConfig {
    /// The transport for `remoteHost`. `local` (or `localhost-dir`) uses `LocalDirectoryTransport`.
    public func remoteTransport() throws -> RemoteTransport {
        guard let host = remoteHost, !host.isEmpty else { throw RemoteError.notConfigured }
        if host == "local" { return LocalDirectoryTransport() }
        return SSHTransport(host: host)
    }
}
