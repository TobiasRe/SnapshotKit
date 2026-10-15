import Foundation

/// Result of a short-lived command whose output is captured in full.
public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { status == 0 }
    public var trimmedOutput: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public struct CommandError: Error, LocalizedError, Sendable {
    public var command: [String]
    public var result: CommandResult

    public var errorDescription: String? {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "`\(command.joined(separator: " "))` exited with \(result.status)" + (detail.isEmpty ? "" : ": \(detail)")
    }
}

/// Runs short commands synchronously and captures stdout/stderr.
public enum Shell {
    /// Runs `arguments[0]` (resolved through `/usr/bin/env`) with the remaining arguments.
    @discardableResult
    public static func run(
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String]? = nil,
        input: Data? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        let exited = exitSemaphore(for: process)

        try process.run()
        if let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }

        // Drain both pipes concurrently so a full stderr buffer cannot block stdout.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        exited.wait()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Like `run`, but throws when the command exits non-zero and returns trimmed stdout.
    @discardableResult
    public static func output(
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> String {
        let result = try run(arguments, in: directory, environment: environment)
        guard result.succeeded else { throw CommandError(command: arguments, result: result) }
        return result.trimmedOutput
    }

    /// Raw stdout bytes, for binary output such as `git show <rev>:<png>`.
    public static func data(_ arguments: [String], in directory: URL? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = exitSemaphore(for: process)
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        guard process.terminationStatus == 0 else {
            throw CommandError(command: arguments, result: CommandResult(status: process.terminationStatus, stdout: "", stderr: ""))
        }
        return data
    }

    /// `Process.waitUntilExit()` spins the current run loop, which re-enters AppKit/SwiftUI
    /// layout when called on the main thread. Waiting on a semaphore does not.
    private static func exitSemaphore(for process: Process) -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        return semaphore
    }

    /// Quotes an argument for display in a copy-pasteable command line.
    public static func quote(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,@+%")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
