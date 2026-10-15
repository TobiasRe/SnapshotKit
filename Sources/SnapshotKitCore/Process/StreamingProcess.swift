import Foundation

/// A long-running child process whose combined stdout/stderr is delivered line by line.
///
/// Cancellation sends SIGINT first (xcodebuild cleans up on SIGINT), escalating to
/// SIGTERM and finally SIGKILL if the process does not exit.
public final class StreamingProcess: @unchecked Sendable {
    public let executable: String
    public let arguments: [String]
    public let directory: URL?
    public let environment: [String: String]

    private let process = Process()
    private let lock = NSLock()
    private var _cancelled = false
    private var continuation: AsyncStream<String>.Continuation?
    private var exitContinuation: CheckedContinuation<Int32, Never>?
    private var exitStatus: Int32?

    /// Output lines without trailing newlines. Finishes when the process exits.
    public let lines: AsyncStream<String>

    public init(executable: String, arguments: [String], directory: URL? = nil, environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        var cont: AsyncStream<String>.Continuation!
        lines = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    public var commandLine: String {
        ([executable] + arguments).map(Shell.quote).joined(separator: " ")
    }

    public var isCancelled: Bool { lock.withLock { _cancelled } }
    public var processIdentifier: Int32 { process.processIdentifier }

    public func start() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let directory { process.currentDirectoryURL = directory }
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = LineBuffer()
        let handle = pipe.fileHandleForReading
        let readDone = DispatchSemaphore(value: 0)
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                for line in buffer.flush() { self?.continuation?.yield(line) }
                readDone.signal()
                return
            }
            for line in buffer.append(data) { self?.continuation?.yield(line) }
        }

        process.terminationHandler = { [weak self] proc in
            ChildProcesses.shared.remove(proc.processIdentifier)
            // Wait (briefly) for the reader to drain the pipe before finishing the stream.
            _ = readDone.wait(timeout: .now() + 2)
            guard let self else { return }
            self.continuation?.finish()
            self.lock.withLock {
                self.exitStatus = proc.terminationStatus
                self.exitContinuation?.resume(returning: proc.terminationStatus)
                self.exitContinuation = nil
            }
        }
        try process.run()
        ChildProcesses.shared.add(process.processIdentifier)
    }

    /// Waits for the process to exit and returns its status.
    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { cont in
            lock.lock()
            if let status = exitStatus {
                lock.unlock()
                cont.resume(returning: status)
            } else {
                exitContinuation = cont
                lock.unlock()
            }
        }
    }

    /// Interrupts the process, escalating if it does not exit in time.
    public func cancel(grace: TimeInterval = 8) {
        lock.withLock { _cancelled = true }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [process] in
            guard process.isRunning else { return }
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}

/// Long-running children of this process, so they can be stopped when SnapshotKit is
/// interrupted or quits — an orphaned xcodebuild could otherwise keep recording snapshots.
public final class ChildProcesses: @unchecked Sendable {
    public static let shared = ChildProcesses()
    private let lock = NSLock()
    private var pids = Set<Int32>()

    func add(_ pid: Int32) { lock.withLock { _ = pids.insert(pid) } }
    func remove(_ pid: Int32) { lock.withLock { _ = pids.remove(pid) } }
    public var running: [Int32] { lock.withLock { Array(pids) } }

    /// Interrupts all children, waits up to `timeout` for them to exit, then kills the rest.
    public func terminateAll(timeout: TimeInterval = 5) {
        let children = running
        guard !children.isEmpty else { return }
        for pid in children { kill(pid, SIGINT) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, children.contains(where: { kill($0, 0) == 0 && !isZombie($0) }) {
            usleep(100_000)
        }
        for pid in children where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    private func isZombie(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size > 0 && info.pbi_status == SZOMB
    }
}

/// Splits a byte stream into lines, handling `\r` progress updates and partial UTF-8.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = pending[pending.startIndex..<index]
                lines.append(String(decoding: lineData, as: UTF8.self))
                pending.removeSubrange(pending.startIndex...index)
            }
            return lines.filter { !$0.isEmpty }
        }
    }

    func flush() -> [String] {
        lock.withLock {
            defer { pending.removeAll() }
            let rest = String(decoding: pending, as: UTF8.self)
            return rest.isEmpty ? [] : [rest]
        }
    }
}
