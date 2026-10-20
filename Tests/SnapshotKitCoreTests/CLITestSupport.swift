import Foundation
import Testing
@testable import SnapshotKitCore

/// The built `snapkit`, run the way a user runs it, with a settings folder of its own (settings,
/// history and the patch registry), so tests running in parallel never see each other's.
struct Snapkit {
    /// SwiftPM builds every product before the tests, into the folder that holds the test bundle
    /// (which may hold this target's resource bundle in turn).
    static let executable: URL = {
        var folder = Bundle.module.bundleURL
        for _ in 0..<5 {
            folder.deleteLastPathComponent()
            let candidate = folder.appendingPathComponent("snapkit")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("snapkit")
    }()

    let home = testTemp("cli-home")

    var settings: ProjectStore { ProjectStore(url: home.appendingPathComponent("settings.json")) }

    func history(of repository: URL) -> RunHistory { RunHistory(repository: repository, home: home) }

    /// Runs `snapkit arguments…` in `directory`. Output is a pipe, so it must never be colored:
    /// `NO_COLOR` is empty, which leaves that to the terminal check alone.
    @discardableResult
    func callAsFunction(_ arguments: String..., in directory: URL? = nil, environment: [String: String] = [:],
                        sourceLocation: SourceLocation = #_sourceLocation) throws -> CommandResult {
        try run(arguments, in: directory, environment: environment, sourceLocation: sourceLocation)
    }

    func run(_ arguments: [String], in directory: URL? = nil, environment: [String: String] = [:],
             sourceLocation: SourceLocation = #_sourceLocation) throws -> CommandResult {
        try #require(FileManager.default.isExecutableFile(atPath: Self.executable.path),
                     "\(Self.executable.path) is missing: build the package first", sourceLocation: sourceLocation)
        let result = try Shell.run([Self.executable.path] + arguments, in: directory ?? FileManager.default.temporaryDirectory,
                                   environment: self.environment(environment))
        #expect(!(result.stdout + result.stderr).contains("\u{1B}["), "colored output on a pipe", sourceLocation: sourceLocation)
        return result
    }

    /// Runs `snapkit arguments…` and presses Ctrl-C once `marker` exists: a stand-in creates it
    /// where the interrupt is to come.
    func interrupted(_ arguments: String..., at marker: URL, environment: [String: String] = [:],
                     sourceLocation: SourceLocation = #_sourceLocation) throws -> CommandResult {
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(self.environment(environment)) { $1 }
        let stdout = Pipe(), stderr = Pipe()
        (process.standardOutput, process.standardError) = (stdout, stderr)
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: marker.path), process.isRunning, Date() < deadline { usleep(20_000) }
        #expect(FileManager.default.fileExists(atPath: marker.path), "never got to the interrupt", sourceLocation: sourceLocation)
        kill(process.processIdentifier, SIGINT)
        let out = stdout.fileHandleForReading.readDataToEndOfFile(), err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
    }

    private func environment(_ extra: [String: String]) -> [String: String] {
        ["SNAPSHOTKIT_HOME": home.path, "NO_COLOR": "", "SNAPSHOTKIT_XCODE_SEARCH_PATHS": ""].merging(extra) { $1 }
    }
}

extension TempRepo {
    /// The repository as `snapkit` names it: git's `--show-toplevel`, which resolves `/var` to `/private/var`.
    var root: String { Git.repository(containing: url)!.root.path }
}

/// What `snapkit` writes and how it exits, compared as a whole.
struct Outcome: Equatable, CustomStringConvertible {
    var status: Int32
    var stdout = ""
    var stderr = ""

    init(_ result: CommandResult) {
        status = result.status
        stdout = result.stdout
        stderr = result.stderr
    }

    init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    var description: String { "exit \(status)\n--- stdout\n\(stdout)--- stderr\n\(stderr)" }
}

/// An error as `snapkit` prints it for wrong options or arguments (exit status 64).
func usageFailure(_ message: String) -> Outcome {
    Outcome(status: 64, stderr: "error: \(message)\nRun `snapkit help` for usage.\n")
}

/// An error as `snapkit` prints it.
func failure(_ message: String, status: Int32 = 1, stdout: String = "") -> Outcome {
    Outcome(status: status, stdout: stdout, stderr: "error: \(message)\n")
}
