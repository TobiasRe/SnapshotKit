import AppKit
import SnapshotKitCore
import SwiftUI
@testable import SnapshotKit

/// Deterministic state for rendering the app's views: no git, Xcode, simulator or clock involved.
@MainActor
enum AppFixtures {
    static let repository = URL(fileURLWithPath: "/work/SampleApp")
    static let date = Date(timeIntervalSince1970: 1_800_000_000) // fixed
    static let snapshotDir = "Tests/AppSnapshotTests/__Snapshots__"

    // MARK: Images

    /// A small mock of an app screen: card, title bar, text lines and a button in `accent`.
    static func screen(accent: NSColor, titleWidth: CGFloat = 0.6, badge: Bool = false) -> Data {
        let size = CGSize(width: 360, height: 240)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill(); rect.fill()
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 20, dy: 20), xRadius: 14, yRadius: 14)
            NSColor(white: 0.96, alpha: 1).setFill(); card.fill()
            NSColor(white: 0.25, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 40, y: 40, width: 280 * titleWidth, height: 18), xRadius: 4, yRadius: 4).fill()
            NSColor(white: 0.75, alpha: 1).setFill()
            for (i, w) in [0.9, 0.75, 0.82].enumerated() {
                NSBezierPath(roundedRect: CGRect(x: 40, y: 76 + CGFloat(i) * 20, width: 280 * w, height: 9), xRadius: 3, yRadius: 3).fill()
            }
            accent.setFill()
            NSBezierPath(roundedRect: CGRect(x: 40, y: 160, width: 140, height: 36), xRadius: 10, yRadius: 10).fill()
            if badge {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: CGRect(x: 290, y: 30, width: 22, height: 22)).fill()
            }
            return true
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static let reference = screen(accent: .systemBlue)
    static let actual = screen(accent: .systemOrange, titleWidth: 0.5)
    static let badged = screen(accent: .systemBlue, badge: true)

    // MARK: Configuration

    static var context: ProjectContext {
        var config = SnapshotConfig()
        config.scheme = "SampleApp"
        config.workspace = "SampleApp.xcworkspace"
        config.testPlan = "Snapshots"
        config.xcodeVersion = "99.1"
        config.deviceName = "Example Phone"
        config.osVersion = "99.0"
        config.baseBranch = "develop"
        let ci = ".gitlab-ci.yml"
        config.sources = ["scheme": ci, "workspace": ci, "testPlan": ci, "xcode": ci, "device": ci, "os": ci, "baseBranch": ci]
        let resolved = ResolvedConfig(repository: repository, config: config, ciFiles: [ci], overrideFile: nil, notes: [])
        return ProjectContext(repository: repository, resolved: resolved)
    }

    static let environment = TestEnvironment(
        xcode: XcodeInstall(path: "/Applications/Xcode.app", version: "99.1", build: "99A1"),
        simulator: Simulator(name: "Example Phone", udid: "00000000-0000-0000-0000-000000000000", osVersion: "99.0", platform: "iOS", state: "Booted"),
        xcodeIsDefault: false
    )

    static let log = [
        "$ xcodebuild test -workspace SampleApp.xcworkspace -scheme SampleApp -testPlan Snapshots -destination 'platform=iOS Simulator,id=00000000'",
        "Resolve Package Graph",
        "◇ Test run started.",
        "◇ Suite CheckoutViewTests started.",
        "◇ Test payButton() started.",
        "✘ Test payButton() recorded an issue at CheckoutViewTests.swift:24:9: Issue recorded",
        "↳ Snapshot does not match reference.",
        "✘ Test payButton() failed after 0.412 seconds with 1 issue.",
        "◇ Test summary() started.",
        "✔ Test summary() passed after 0.208 seconds.",
        "✘ Suite CheckoutViewTests failed after 0.622 seconds with 1 issue.",
        "** TEST FAILED **",
    ]

    // MARK: Results

    static let checkoutSuite = SuiteResult(
        bundle: "AppSnapshotTests", path: ["CheckoutViewTests"],
        tests: [
            TestCaseResult(name: "payButton()", identifier: "CheckoutViewTests/payButton()", outcome: .failed,
                           failureMessages: ["Issue recorded: Snapshot does not match reference."],
                           repetitions: [.passed, .failed, .failed, .passed, .failed]),
            TestCaseResult(name: "summary()", identifier: "CheckoutViewTests/summary()", outcome: .passed, failureMessages: [], repetitions: [.passed]),
        ],
        failureFiles: []
    )

    static let profileSuite = SuiteResult(
        bundle: "AppSnapshotTests", path: ["ProfileViewTests"],
        tests: [TestCaseResult(name: "badge()", identifier: "ProfileViewTests/badge()", outcome: .failed,
                               failureMessages: ["Issue recorded: Snapshot does not match reference."], repetitions: [.failed])],
        failureFiles: []
    )

    static var lastResult: TestRunResult {
        TestRunResult(commandLine: log[0].dropFirst(2).description, exitStatus: 65, cancelled: false,
                      resultBundle: URL(fileURLWithPath: "/tmp/run.xcresult"),
                      summary: TestRunSummary(suites: [checkoutSuite, profileSuite]),
                      passed: 1, failed: 2, skipped: 0, buildErrors: [])
    }

    /// Writes reference/actual PNGs to a temp folder and returns failure items pointing at them.
    static func failures(in dir: URL) -> [FailureItem] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ data: Data, _ name: String) -> URL {
            let url = dir.appendingPathComponent(name)
            try? data.write(to: url)
            return url
        }
        let ref = write(reference, "reference.png"), act = write(actual, "failure.png")
        let ref2 = write(reference, "reference2.png"), act2 = write(badged, "failure2.png")
        let pay = checkoutSuite.tests[0], badge = profileSuite.tests[0]
        let items = [
            FailureItem(
                suite: checkoutSuite, test: pay,
                images: [SnapshotFailureImages(testIdentifier: pay.identifier, repetition: 1, index: 0, reference: ref, failure: act,
                                               difference: nil, device: "Example Phone")],
                referencePaths: ["\(snapshotDir)/CheckoutViewTests/payButton.1.png"],
                verdict: .flaky,
                historyFlaky: FlakySignal(test: "AppSnapshotTests/CheckoutViewTests/payButton()", passes: 3, failures: 4, failingHosts: ["ci-mac"])
            ),
            FailureItem(
                suite: profileSuite, test: badge,
                images: [SnapshotFailureImages(testIdentifier: badge.identifier, repetition: 1, index: 0, reference: ref2, failure: act2,
                                               difference: nil, device: "Example Phone")],
                referencePaths: ["\(snapshotDir)/ProfileViewTests/badge.1.png"],
                verdict: .alwaysFails, historyFlaky: nil
            ),
        ]
        // Thumbnails and compare pairs are normally decoded in the background; warm the caches
        // so the first rendered frame is complete.
        for item in items {
            let failure = item.images.first?.failure
            ThumbnailCache.preload(id: "failure:\(item.id)#\(failure?.path ?? "")", data: failure.flatMap { try? Data(contentsOf: $0) })
            let pair = ComparePair.make(before: try? Data(contentsOf: item.images[0].reference!), after: try? Data(contentsOf: item.images[0].failure!))
            ComparePairCache.store(pair, for: item.id + "#1")
        }
        return items
    }

    // MARK: Changes

    static let changes: [(SnapshotChange, Data?, Data?)] = [
        (SnapshotChange(path: "\(snapshotDir)/CheckoutViewTests/payButton.1.png", kind: .committed), reference, actual),
        (SnapshotChange(path: "\(snapshotDir)/CheckoutViewTests/summary.1.png", kind: .uncommitted), reference, screen(accent: .systemGreen)),
        (SnapshotChange(path: "\(snapshotDir)/ProfileViewTests/badge.1.png", kind: .new), nil, badged),
        (SnapshotChange(path: "\(snapshotDir)/ProfileViewTests/legacyHeader.1.png", kind: .deleted), screen(accent: .systemGray), nil),
    ]

    static var changeSet: SnapshotChangeSet {
        SnapshotChangeSet(baseBranch: "develop", baseRef: "origin/develop", diffBase: .mergeBase,
                          baseCommit: "3f1c2a9d0b7e4c55a1e2f3d4c5b6a7980e1d2c3b", changes: changes.map(\.0))
    }

    static func warmChangeCaches() {
        let set = changeSet
        for (change, base, current) in changes {
            ThumbnailCache.preload(id: "change:\(change.path)#\(change.kind)", data: current ?? base)
            ComparePairCache.store(ComparePair.make(before: base, after: current),
                                   for: change.id + "#" + set.baseCommit + "#\(change.kind)")
        }
    }

    // MARK: Models

    static func store() -> ProjectStore {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-app-tests-\(UUID().uuidString)")
        setenv("SNAPSHOTKIT_HOME", home.path, 1)
        let store = ProjectStore(url: home.appendingPathComponent("settings.json"))
        store.update { s in
            s.discovered = ["/work/SampleApp", "/work/design-system", "/work/onboarding-flow", "/work/payments-ui"]
            s.pinned = ["/work/design-system"]
            s.recents = ["/work/SampleApp"]
        }
        return store
    }

    enum Scenario { case failedRun, running, changes, failures, empty, missingXcode, brokenConfig, missingBaseBranch, neverRun }

    static func project(_ scenario: Scenario, store: ProjectStore) -> ProjectModel {
        let model = ProjectModel(project: Project(path: repository.path), store: store, autoload: false)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-app-fixtures")
        var f = ProjectFixture()
        f.context = context
        f.environment = environment
        f.modules = ["AppSnapshotTests", "DesignSystemSnapshotTests"]
        f.currentBranch = "feature/checkout-redesign"
        f.changeSet = changeSet
        f.changeImages = Dictionary(uniqueKeysWithValues: changes.map { ($0.0.path, ($0.1, $0.2)) })
        f.failingSuites = [checkoutSuite, profileSuite]
        f.failures = failures(in: tmp)
        f.failureSource = FailureSource(label: "Last run", date: date, host: "local")
        f.historyFlaky = [f.failures[0].historyFlaky!]
        warmChangeCaches()

        switch scenario {
        case .failedRun:
            f.tab = .run
            f.passed = 1
            f.failed = 2
            f.log = log
            f.lastResult = lastResult
            f.lastMessage = ProjectModel.failureTitle(tests: 2, suites: 2)
            f.lastMessageIsError = true
            f.lastDuration = 94
        case .running:
            f.tab = .run
            f.operation = .run
            f.stageLabel = "Running tests"
            f.phase = .testing
            f.passed = 12
            f.failed = 1
            f.expectedTotal = 30
            f.currentTest = "summary()"
            f.log = Array(log.prefix(9))
        case .changes:
            f.tab = .changes
        case .failures:
            f.tab = .failures
        case .missingXcode:
            f.tab = .run
            f.environment = nil
            f.environmentError = EnvironmentError.xcodeNotInstalled(
                required: "99.2", source: ".gitlab-ci.yml",
                installed: [XcodeInstall(path: "/Applications/Xcode.app", version: "99.1")]).errorDescription
            f.failingSuites = []
            f.failures = []
            f.failureSource = nil
        case .brokenConfig:
            f.tab = .run
            f.context = nil
            f.environment = nil
            f.configError = ConfigError.invalidOverride("line 3: nested mappings are not supported").errorDescription
        case .missingBaseBranch:
            f.tab = .changes
            f.changeSet = nil
            f.changesError = SnapshotChangeError.baseBranchNotFound("develop").errorDescription
        case .neverRun:
            f.tab = .run
            f.failingSuites = []
            f.failures = []
            f.failureSource = nil
            f.historyFlaky = []
        case .empty:
            f.tab = .run
            f.failingSuites = []
            f.failures = []
            f.failureSource = nil
            f.historyFlaky = []
            f.changeSet = SnapshotChangeSet(baseBranch: "develop", baseRef: "origin/develop", diffBase: .mergeBase,
                                            baseCommit: "3f1c2a9d0b7e4c55a1e2f3d4c5b6a7980e1d2c3b", changes: [])
        }
        model.apply(f)
        return model
    }
}
