import Foundation

/// How SnapshotKit reaches a remote machine: run shell scripts there and copy files both ways.
public protocol RemoteTransport: Sendable {
    /// Shown in the UI and stored in run history ("ci-mac-1").
    var label: String { get }
    /// Executable and arguments that run `script` with bash on the remote machine.
    /// `interactive` allocates a TTY so that killing the local process stops the remote one.
    func command(for script: String, interactive: Bool) -> (executable: String, arguments: [String])
    /// rsync destination/source prefix for a remote path (`host:/path` or just `/path`).
    func rsyncLocation(_ remotePath: String) throws -> String
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
            throw RemoteError.commandFailed(host: label, script: script, status: result.status,
                                            output: (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    /// Copies the listed files (relative to `localRoot`) into `remoteDirectory`.
    public func upload(files: [String], from localRoot: URL, to remoteDirectory: String) throws {
        try rsync(files: files, from: localRoot.path + "/", to: try rsyncLocation(remoteDirectory) + "/")
    }

    /// Copies the listed files (relative to `remoteDirectory`) into `localRoot`. Unlike
    /// `download(_:to:)`, their names may contain anything: rsync sends the list itself, not the
    /// remote shell.
    public func download(files: [String], from remoteDirectory: String, to localRoot: URL) throws {
        try rsync(files: files, from: try rsyncLocation(remoteDirectory) + "/", to: localRoot.path + "/")
    }

    private func rsync(files: [String], from source: String, to destination: String) throws {
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-files-\(UUID().uuidString).txt")
        try files.joined(separator: "\n").appending("\n").write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }
        try rsync(["-a", "--files-from=\(list.path)", source, destination])
    }

    /// Copies a remote file or directory to a local path.
    public func download(_ remotePath: String, to local: URL) throws {
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rsync(["-a", try rsyncLocation(remotePath), local.path])
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
    public let host: String
    public let options: [String]

    /// Throws for a host ssh would read as an option (`-oProxyCommand=…`) or that isn't one word:
    /// `remoteHost` can come from a committed `.snapshotkit.yml`.
    public init(host: String, options: [String] = []) throws {
        guard !host.isEmpty, !host.hasPrefix("-"),
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { throw RemoteError.invalidHost(host) }
        self.host = host
        self.options = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15"] + options
    }

    public var label: String { host }

    public func command(for script: String, interactive: Bool) -> (executable: String, arguments: [String]) {
        ("ssh", options + (interactive ? ["-tt"] : []) + ["--", host, "/bin/bash -lc " + Shell.quote(script)])
    }

    /// The remote shell splits the path rsync passes it (macOS's openrsync has no `--protect-args`,
    /// and quoting would break the rsync versions that escape it themselves), so paths that need
    /// quoting are refused rather than copied somewhere else.
    public func rsyncLocation(_ remotePath: String) throws -> String {
        guard Shell.quote(remotePath) == remotePath else { throw RemoteError.unsafeRemotePath(host: host, path: remotePath) }
        return "\(host):\(remotePath)"
    }

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
    case commandFailed(host: String, script: String, status: Int32, output: String)
    case syncFailed(host: String, output: String)
    case unreachable(host: String, output: String)
    case invalidHost(String)
    case unsafeRemotePath(host: String, path: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No remote machine configured. Set `remoteHost:` in .snapshotkit.yml or in the project's settings."
        case let .commandFailed(host, _, _, output):
            "Command on \(host) failed: \(output)"
        case let .syncFailed(host, output):
            "Copying files to/from \(host) failed: \(output)"
        case let .unreachable(host, output):
            "Cannot reach \(host) over SSH (\(output)). Check that key-based login works: `ssh \(host) true`."
        case let .invalidHost(host):
            "'\(host)' is not a host name SnapshotKit will pass to ssh. Set `remoteHost:` to a host, user@host or an ~/.ssh/config alias."
        case let .unsafeRemotePath(host, path):
            "The folder \(path) on \(host) has spaces or shell characters, which rsync can't pass reliably. Set `remoteDirectory:` to a path without them."
        }
    }
}

extension SnapshotConfig {
    /// The transport for `remoteHost`. `local` uses `LocalDirectoryTransport`.
    public func remoteTransport() throws -> RemoteTransport {
        guard let host = remoteHost, !host.isEmpty else { throw RemoteError.notConfigured }
        if host == "local" { return LocalDirectoryTransport() }
        return try SSHTransport(host: host)
    }
}
