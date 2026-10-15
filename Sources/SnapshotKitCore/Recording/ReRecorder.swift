import Foundation

public enum ReRecordStage: String, Sendable {
    case locating, patching, recording, restoring, verifying, done

    public var label: String {
        switch self {
        case .locating: "Finding suite sources"
        case .patching: "Enabling record mode"
        case .recording: "Recording snapshots"
        case .restoring: "Restoring test sources"
        case .verifying: "Verifying new references"
        case .done: "Done"
        }
    }
}

public struct ReRecordOutcome: Sendable {
    public var suites: [SuiteResult]
    public var patchedFiles: [String]
    public var recordRun: TestRunResult
    public var restore: RestoreReport
    /// Run of the same suites without the patch; nil when verification was skipped or cancelled.
    public var verifyRun: TestRunResult?

    public var verified: Bool { verifyRun?.succeeded == true }
}

/// Re-records only the given (failing) suites:
/// patch record mode in → run those suites → restore sources → optionally run again to verify.
public final class ReRecorder: @unchecked Sendable {
    public let runner: TestRunner
    private let lock = NSLock()
    private var currentRunner: TestRunner?
    private var cancelled = false

    public init(runner: TestRunner) {
        self.runner = runner
    }

    /// Source locations for each suite (relative paths). Throws if any cannot be found.
    public func targets(for suites: [SuiteResult]) throws -> [RecordSession.Target] {
        try suites.map { suite in
            RecordSession.Target(suite: suite.name, path: try SuiteLocator.locate(suite, in: runner.repository))
        }
    }

    public func reRecord(
        suites: [SuiteResult],
        verify: Bool = true,
        onStage: @escaping @Sendable (ReRecordStage) -> Void = { _ in },
        onLine: @escaping @Sendable (String) -> Void = { _ in },
        onEvent: @escaping @Sendable (TestEvent, TestOutputParser) -> Void = { _, _ in }
    ) async throws -> ReRecordOutcome {
        onStage(.locating)
        let targets = try targets(for: suites)
        onStage(.patching)
        let session = try RecordSession.begin(repository: runner.repository, targets: targets)
        for file in session.journal.files { onLine("snapkit: record mode enabled in \(file.path) (\(file.suite))") }

        let recordRun: TestRunResult
        do {
            onStage(.recording)
            recordRun = try await runner.run(onlyTesting: suites.map(\.identifier), onLine: onLine, onEvent: onEvent)
        } catch {
            onStage(.restoring)
            let report = session.restore()
            onLine("snapkit: " + report.summary)
            throw error
        }
        onStage(.restoring)
        let report = session.restore()
        onLine("snapkit: " + report.summary.replacingOccurrences(of: "\n", with: "\nsnapkit: "))

        var verifyRun: TestRunResult?
        if verify && !recordRun.cancelled && !isCancelled {
            onStage(.verifying)
            let verifier = TestRunner(repository: runner.repository, config: runner.config, environment: runner.environment)
            lock.withLock { currentRunner = verifier }
            verifyRun = try await verifier.run(onlyTesting: suites.map(\.identifier), onLine: onLine, onEvent: onEvent)
        }
        onStage(.done)
        return ReRecordOutcome(
            suites: suites,
            patchedFiles: session.journal.files.map(\.path),
            recordRun: recordRun,
            restore: report,
            verifyRun: verifyRun
        )
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        let verifier: TestRunner? = lock.withLock {
            cancelled = true
            return currentRunner
        }
        runner.cancel()
        verifier?.cancel()
    }
}
