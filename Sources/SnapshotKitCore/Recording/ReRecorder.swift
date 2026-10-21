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

/// Re-records the given suites, or just the tests in `onlyTesting`:
/// patch record mode in → run them → restore sources → optionally run again to verify.
public final class ReRecorder: @unchecked Sendable { // `currentRunner` and `cancelled` are guarded by `lock`.
    public let runner: TestRunner
    private let lock = NSLock()
    private var currentRunner: TestRunner?
    private var cancelled = false

    public init(runner: TestRunner) {
        self.runner = runner
    }

    /// Source locations for each suite (relative paths). Throws if any cannot be found.
    public func targets(for suites: [SuiteResult]) throws -> [RecordSession.Target] {
        try SuiteLocator.targets(for: suites, in: runner.repository)
    }

    /// Re-records `suites` (only the tests in `onlyTesting`, when given) and then, with `verify`,
    /// runs them again without the patch. The sources are restored whatever happens, before this
    /// returns or throws.
    public func reRecord(
        suites: [SuiteResult],
        onlyTesting: [String]? = nil,
        verify: Bool = true,
        onStage: @escaping @Sendable (ReRecordStage) -> Void = { _ in },
        onLine: @escaping @Sendable (String) -> Void = { _ in },
        onEvent: @escaping @Sendable (TestEvent, TestOutputParser) -> Void = { _, _ in }
    ) async throws -> ReRecordOutcome {
        onStage(.locating)
        let targets = try await offCooperativePool { try self.targets(for: suites) }
        onStage(.patching)
        let repository = runner.repository
        let session = try await offCooperativePool { try RecordSession.begin(repository: repository, targets: targets) }
        for file in session.journal.files { onLine("snapkit: record mode enabled in \(file.path) (\(file.suite))") }

        let recordRun: TestRunResult
        do {
            onStage(.recording)
            recordRun = try await runner.run(onlyTesting: onlyTesting ?? suites.flatMap(\.onlyTestingIdentifiers), onLine: onLine, onEvent: onEvent)
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
        // A cancelled run, or one whose tests never ran (a failed build), recorded nothing to verify.
        if verify && !recordRun.cancelled && recordRun.nothingTested == nil {
            let verifier = TestRunner(repository: runner.repository, config: runner.config, environment: runner.environment,
                                      xcodebuild: runner.xcodebuild)
            // Checked and published together, so a cancel() in between can't miss the verifier.
            let cancelled = lock.withLock {
                currentRunner = verifier
                return self.cancelled
            }
            if !cancelled {
                onStage(.verifying)
                do {
                    verifyRun = try await verifier.run(onlyTesting: onlyTesting ?? suites.flatMap(\.onlyTestingIdentifiers), onLine: onLine, onEvent: onEvent)
                } catch is CancellationError {}
            }
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

    public func cancel() {
        let verifier: TestRunner? = lock.withLock {
            cancelled = true
            return currentRunner
        }
        runner.cancel()
        verifier?.cancel()
    }
}
