import Foundation

/// The most recent run's failing suites, shared between the CLI and the app via the git directory.
public struct LastRun: Codable, Sendable {
    public var date: Date
    public var host: String
    public var resultBundle: String?
    public var failingSuites: [SuiteResult]
    public var passed: Int
    public var failed: Int
    /// Exported failure attachments (folder with manifest.json), if any.
    public var attachmentsDirectory: String?
    /// Every suite of the run, passing ones included, for the Run tab's results after a
    /// relaunch. Missing in files written by older versions.
    public var suites: [SuiteResult]?
    /// The folder with a failing test's images (by `Bundle/Suite/test()`) when it is not the run's
    /// own: a partial run re-ran some tests, and the others' images are still the earlier run's. An
    /// empty path: the run that last ran the test exported none. Missing in older files.
    public var testAttachments: [String: String]?

    public init(result: TestRunResult, attachmentsDirectory: URL? = nil) {
        date = Date()
        host = result.host
        resultBundle = result.resultBundle.path
        self.attachmentsDirectory = attachmentsDirectory?.path
        failingSuites = result.failingSuites
        suites = result.summary?.suites
        passed = result.passed
        failed = result.failed
    }

    static func url(for repository: URL) throws -> URL {
        try Git(root: repository).gitDirectory().appendingPathComponent("snapshotkit/last-run.json")
    }

    /// When the repository's last run was last saved, by any process (the app, `snapkit`); nil
    /// before the first. Cheaper than loading it, to tell whether it changed.
    public static func savedDate(repository: URL) -> Date? {
        guard let url = try? url(for: repository) else { return nil }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    public static func load(repository: URL) -> LastRun? {
        guard let url = try? url(for: repository), let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var last = try? decoder.decode(LastRun.self, from: data) else { return nil }
        // The paths name the folder the repository was in, which it may since have moved or been
        // copied from: what is in its own results folder wins.
        let results = TestRunner.resultsDirectory(for: repository)
        func here(_ path: String?) -> String? {
            guard let path, !path.isEmpty else { return path }
            let local = results.appendingPathComponent((path as NSString).lastPathComponent).path
            return FileManager.default.fileExists(atPath: local) ? local : path
        }
        last.resultBundle = here(last.resultBundle)
        last.attachmentsDirectory = here(last.attachmentsDirectory)
        last.testAttachments = last.testAttachments?.mapValues { here($0) ?? $0 }
        return last
    }

    /// Takes in `run` as the repository's last run. A cancelled run changes nothing, nor does one in
    /// which no test ran (the build failed): they have no results to speak of. A `partial` run of some
    /// tests (a re-record's verification) replaces only those tests' results and images; its bundle
    /// becomes the last run's when no failure is left outside it.
    public static func update(with run: TestRunResult, partial: Bool = false, attachmentsDirectory: URL? = nil, repository: URL) {
        guard !run.cancelled, run.nothingTested == nil else { return }
        guard partial, var last = load(repository: repository) else {
            LastRun(result: run, attachmentsDirectory: attachmentsDirectory).save(repository: repository)
            return
        }
        last.merge(run, attachmentsDirectory: attachmentsDirectory)
        last.save(repository: repository)
    }

    /// Replaces the results of the tests `run` ran by its own; every failing test keeps the images of
    /// the run that last ran it.
    mutating func merge(_ run: TestRunResult, attachmentsDirectory newImages: URL?) {
        let ran = run.summary?.suites ?? []
        let ranTests = Set(ran.flatMap { suite in suite.tests.map { suite.identifier + "/" + $0.name } })
        let earlier = self
        date = Date()
        failingSuites = SuiteResult.merging(ran, into: failingSuites).filter(\.isFailing)
        failed = failingSuites.reduce(0) { $0 + $1.failedCount }
        if let all = suites.map({ SuiteResult.merging(ran, into: $0) }) {
            suites = all
            passed = all.reduce(0) { $0 + $1.passedCount }
        }
        let failing = Self.failingTests(in: failingSuites)
        if failing.allSatisfy(ranTests.contains) {
            host = run.host
            resultBundle = run.resultBundle.path
            attachmentsDirectory = newImages?.path
        }
        var folders: [String: String] = [:]
        for test in failing {
            folders[test] = ranTests.contains(test) ? newImages?.path ?? "" : earlier.imagesPath(for: test) ?? ""
        }
        let own = runImagesPath ?? ""
        let elsewhere = folders.filter { $0.value != own }
        testAttachments = elsewhere.isEmpty ? nil : elsewhere
    }

    private static func failingTests(in suites: [SuiteResult]) -> [String] {
        suites.flatMap { suite in suite.tests.filter { $0.outcome == .failed }.map { suite.identifier + "/" + $0.name } }
    }

    /// Its result bundle and every folder of images it takes failures' images from: an earlier
    /// run's, for a failing test that a re-record's verification since didn't run.
    var referencedPaths: [String] {
        ([resultBundle, attachmentsDirectory].compactMap { $0 } + (testAttachments.map { Array($0.values) } ?? [])).filter { !$0.isEmpty }
    }

    /// The run's own images: the exported folder, else the one next to its bundle (older files name none).
    private var runImagesPath: String? {
        attachmentsDirectory ?? resultBundle.map { ($0 as NSString).deletingPathExtension + ".attachments" }
    }

    private func imagesPath(for test: String, ownImages: URL? = nil) -> String? {
        testAttachments?[test] ?? ownImages?.path ?? runImagesPath
    }

    /// The folder with the failure images of `test` (`Bundle/Suite/test()`), if any.
    public func attachmentsDirectory(for test: String) -> URL? {
        attachmentsDirectory(for: test, ownImages: nil)
    }

    private func attachmentsDirectory(for test: String, ownImages: URL?) -> URL? {
        imagesPath(for: test, ownImages: ownImages).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    /// The failing tests' images, each test's from the run that last ran it. `ownImages`: where the
    /// run's bundle was exported again, to take the run's own images from instead.
    public func failureImages(ownImagesIn ownImages: URL? = nil) -> [SnapshotFailureImages] {
        var tests: [URL: [(test: TestCaseResult, suite: SuiteResult)]] = [:]
        for suite in failingSuites {
            for test in suite.tests where test.outcome == .failed {
                if let folder = attachmentsDirectory(for: suite.identifier + "/" + test.name, ownImages: ownImages) {
                    tests[folder, default: []].append((test, suite))
                }
            }
        }
        return tests.sorted { $0.key.path < $1.key.path }.flatMap { folder, tests -> [SnapshotFailureImages] in
            guard let manifest = FileManager.default.contents(atPath: folder.appendingPathComponent("manifest.json").path),
                  let images = try? FailureAttachments.parse(manifest: manifest, directory: folder) else { return [] }
            return images.filter { image in tests.contains { image.belong(to: $0.test, in: $0.suite) } }
        }
    }

    public func save(repository: URL) {
        guard let url = try? Self.url(for: repository) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}
