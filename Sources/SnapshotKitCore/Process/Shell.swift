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
///
/// These calls block until the command exits; async code runs them through `offCooperativePool`.
public enum Shell {
    /// Runs `arguments[0]` (resolved through `/usr/bin/env`) with the remaining arguments.
    @discardableResult
    public static func run(
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String]? = nil,
        input: Data? = nil
    ) throws -> CommandResult {
        let (status, out, err) = try execute(arguments, in: directory, environment: environment, input: input)
        return CommandResult(status: status, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
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
        let (status, out, err) = try execute(arguments, in: directory, environment: nil, input: nil)
        guard status == 0 else {
            throw CommandError(command: arguments, result: CommandResult(status: status, stdout: "", stderr: String(decoding: err, as: UTF8.self)))
        }
        return out
    }

    private static func execute(
        _ arguments: [String], in directory: URL?, environment: [String: String]?, input: Data?
    ) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe.private(), err = Pipe.private()
        process.standardOutput = out
        process.standardError = err
        let inPipe = input == nil ? nil : Pipe.private()
        process.standardInput = inPipe ?? FileHandle.nullDevice
        let exited = exitSemaphore(for: process)

        try process.run()
        out.closeWriteEndInParent()
        err.closeWriteEndInParent()
        if let input, let inPipe {
            try? inPipe.fileHandleForReading.close()
            let handle = inPipe.fileHandleForWriting
            // A child that exits without reading all of it must not take us down with SIGPIPE;
            // the write fails with EPIPE instead.
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            // Written while the output is drained below: a child that fills its output pipe before
            // it has read all its input would otherwise wait for us while we wait for it.
            Thread {
                try? handle.write(contentsOf: input)
                try? handle.close()
            }.start()
        }

        // Drain both pipes concurrently so a full stderr buffer cannot block stdout. A dedicated
        // thread, not the global queue: that queue has only as many threads as cores, and when
        // they are all blocked in here (parallel tests, background tasks) the drain never runs.
        let errData = LockedData()
        let errDone = DispatchSemaphore(value: 0)
        let reader = Thread {
            errData.value = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        reader.start()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        waitForExit(process, exited)
        return (process.terminationStatus, outData, errData.value)
    }

    /// `Process.waitUntilExit()` spins the current run loop, which re-enters AppKit/SwiftUI
    /// layout when called on the main thread. Waiting on a semaphore does not.
    private static func exitSemaphore(for process: Process) -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        return semaphore
    }

    /// Waits for the termination handler, but doesn't rely on it alone: once in a while it is
    /// never delivered (seen as a test run hanging forever after `git init` had exited).
    /// `isRunning` doesn't spin the run loop either.
    private static func waitForExit(_ process: Process, _ exited: DispatchSemaphore) {
        while exited.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
            if !process.isRunning { return }
        }
    }

    /// Quotes an argument for display in a copy-pasteable command line.
    public static func quote(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,@+%")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Bytes handed from the reader thread back to the caller.
private final class LockedData: @unchecked Sendable { // `data` is only touched under `lock`.
    private let lock = NSLock()
    private var data = Data()
    var value: Data {
        get { lock.withLock { data } }
        set { lock.withLock { data = newValue } }
    }
}

extension Pipe {
    /// A pipe whose descriptors are close-on-exec, so a child spawned concurrently on another
    /// thread can't inherit them. (An inherited write end keeps the reader waiting for EOF until
    /// that unrelated child exits; this hung test runs.) The child this pipe is meant for still
    /// gets it as stdin/stdout/stderr, since those are set up with dup2, which clears the flag.
    static func `private`() -> Pipe {
        let pipe = Pipe()
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        return pipe
    }

    /// The child has its own copy now; ours must go, or reading never sees end-of-file.
    func closeWriteEndInParent() {
        try? fileHandleForWriting.close()
    }
}

/// Runs blocking work (a `Shell` call, say) on a thread of its own and waits for it without
/// blocking: Swift concurrency's pool has a thread per core, and work that sits in `waitpid` or
/// `read` there starves every other task.
@discardableResult
func offCooperativePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try work() }) }.start()
    }
}
