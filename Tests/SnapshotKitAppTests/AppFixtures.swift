import AppKit
import SnapshotKitCore
import SwiftUI
import Testing
@testable import SnapshotKitUI

/// Every app test suite lives in here and runs one after another. Suites run in parallel by
/// default, and app tests share the main thread, windows and caches: a window opened by the
/// accessibility audit could shift a snapshot rendered at the same moment by a point or two.
@Suite(.serialized)
enum AppUITests {}

/// Deterministic state for rendering the app's views: no git, Xcode, simulator or clock involved.
@MainActor
enum AppFixtures {
    static let repository = URL(fileURLWithPath: "/work/SampleApp")
    static let date = Date(timeIntervalSince1970: 1_800_000_000) // fixed
    static let snapshotDir = "Tests/AppSnapshotTests/__Snapshots__"

    // MARK: Images

    /// A small mock of an app screen: card, title bar, text lines and a button in `accent`.
    static func screen(accent: NSColor, titleWidth: CGFloat = 0.6, badge: Bool = false, height: CGFloat = 240) -> Data {
        let size = CGSize(width: 360, height: height)
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
    /// The reference with its button a hair lighter: fails an exact comparison, looks the same.
    static let renderingNoise = screen(accent: NSColor.systemBlue.blended(withFraction: 0.008, of: .white)!)

    // MARK: Configuration

    static var context: ProjectContext { context(at: repository) }

    static func context(at repository: URL, xcode: String = "99.1", remoteHost: String? = nil) -> ProjectContext {
        var config = SnapshotConfig()
        config.scheme = "SampleApp"
        config.workspace = "SampleApp.xcworkspace"
        config.testPlan = "Snapshots"
        config.xcodeVersion = xcode
        config.deviceName = "Example Phone"
        config.osVersion = "99.0"
        config.baseBranch = "develop"
        config.remoteHost = remoteHost
        let ci = ".gitlab-ci.yml"
        // The device comes from the override file, so the inspector names that one source.
        config.sources = ["scheme": ci, "workspace": ci, "testPlan": ci, "xcode": ci, "device": ".snapshotkit.yml", "os": ".snapshotkit.yml", "baseBranch": ci]
        let resolved = ResolvedConfig(repository: repository, config: config, ciFiles: [ci], overrideFile: ".snapshotkit.yml", notes: [])
        return ProjectContext(repository: repository, resolved: resolved)
    }

    static let environment = TestEnvironment(
        xcode: XcodeInstall(path: "/Applications/Xcode.app", version: "99.1", build: "99A1"),
        simulator: Simulator(name: "Example Phone", udid: "00000000-0000-0000-0000-000000000000", osVersion: "99.0", platform: "iOS", state: "Booted"),
        xcodeIsDefault: false
    )

    /// An environment whose xcodebuild is the shell `script`, for running operations without Xcode.
    /// `/usr/bin/xcodebuild` and `/usr/bin/xcrun` hand over to `$DEVELOPER_DIR/usr/bin/xcrun <tool> …`.
    /// Every run's result bundle reads as `testResults` (xcresulttool's JSON), or as unreadable, and
    /// exports the files in the folder `attachments` (a manifest.json and its images), or none.
    /// It is Xcode 99.1 with an Example Phone on iOS 99.0, for a configuration that names it by its
    /// folder (`developerDir`).
    static func fakeXcode(_ script: String, testResults: String? = nil, attachments: URL? = nil) throws -> TestEnvironment {
        let app = temporaryDirectory("xcode").appendingPathComponent("Xcode.app")
        let xcrun = app.appendingPathComponent("Contents/Developer/usr/bin/xcrun")
        try FileManager.default.createDirectory(at: xcrun.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": environment.xcode.version],
                                           format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/version.plist"))
        try """
            #!/bin/sh
            if [ "$1 $2" = "simctl list" ]; then
            echo '{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-99-0": [{"name": "\(environment.simulator.name)", "udid": "\(environment.simulator.udid)", "state": "Booted"}]}}'
            exit
            fi
            if [ "$1 $2 $3 $4" = "xcresulttool get test-results tests" ]; then
            \(testResults.map { "cat <<'JSON'\n\($0)\nJSON" } ?? "exit 1")
            exit
            fi
            if [ "$1 $2 $3" = "xcresulttool export attachments" ]; then
            \(attachments.map { "cp -R '\($0.path)/.' \"$7\"" } ?? "exit 1")
            exit
            fi
            [ "$1" = xcodebuild ] || exit 1
            for arg; do [ "$previous" = -resultBundlePath ] && mkdir -p "$arg"; previous=$arg; done
            \(script)

            """.write(to: xcrun, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
        var fake = environment
        fake.xcode = XcodeInstall(path: app.path, version: environment.xcode.version)
        return fake
    }

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

    /// Daily runs ending at `date`, alternating between this machine and CI.
    static func timeline(_ results: [HistoryPoint.Result]) -> [HistoryPoint] {
        results.enumerated().map { i, result in
            HistoryPoint(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!,
                         date: date.addingTimeInterval(Double(i - results.count) * 86_400),
                         kind: .run, host: i.isMultiple(of: 2) ? "local" : "ci-mac", commit: "3f1c2a9", result: result)
        }
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
        // badge() fails on every run, but invisibly: rendered on another machine or OS version.
        let ref2 = write(reference, "reference2.png"), act2 = write(renderingNoise, "failure2.png")
        let pay = checkoutSuite.tests[0], badge = profileSuite.tests[0]
        let items = [
            FailureItem(
                suite: checkoutSuite, test: pay,
                // A flakiness check: it failed in runs 2, 3 and 5 of 5, each with its own images.
                images: [2, 3, 5].map {
                    SnapshotFailureImages(testIdentifier: pay.identifier, repetition: $0, index: 0, reference: ref, failure: act,
                                          difference: nil, device: "Example Phone")
                },
                referencePaths: ["\(snapshotDir)/CheckoutViewTests/payButton.1.png"],
                verdict: .flaky,
                historyFlaky: FlakySignal(test: "AppSnapshotTests/CheckoutViewTests/payButton()", passes: 3, failures: 4, failingHosts: ["ci-mac"]),
                timeline: timeline([.passed, .failed, .passed, .passed, .mixed, .failed, .passed, .failed])
            ),
            FailureItem(
                suite: profileSuite, test: badge,
                images: [SnapshotFailureImages(testIdentifier: badge.identifier, repetition: 1, index: 0, reference: ref2, failure: act2,
                                               difference: nil, device: "Example Phone")],
                referencePaths: ["\(snapshotDir)/ProfileViewTests/badge.1.png"],
                verdict: .alwaysFails, historyFlaky: nil,
                timeline: timeline([.passed, .passed, .passed, .passed, .failed, .failed])
            ),
        ]
        // Thumbnails and compare pairs are normally decoded in the background; warm the caches
        // so the first rendered frame is complete.
        for item in items {
            let failure = item.images.first?.failure
            ThumbnailCache.preload(id: "failure:\(item.id)#\(failure?.path ?? "")", data: failure.flatMap { try? Data(contentsOf: $0) })
            let pair = ComparePair.make(before: try? Data(contentsOf: item.images[0].reference!), after: try? Data(contentsOf: item.images[0].failure!))
            ComparePairCache.store(pair, for: item.id + "#" + item.images[0].id)
        }
        return items
    }

    // MARK: Changes

    static let changes: [(SnapshotChange, Data?, Data?)] = [
        (SnapshotChange(path: "\(snapshotDir)/CheckoutViewTests/payButton.1.png", kind: .committed), reference, actual),
        // Re-recorded on this machine, but only rendering noise changed.
        (SnapshotChange(path: "\(snapshotDir)/CheckoutViewTests/summary.1.png", kind: .uncommitted), reference, renderingNoise),
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
            ThumbnailCache.preload(id: change.thumbnailID, data: current ?? base)
            ComparePairCache.store(ComparePair.make(before: base, after: current),
                                   for: change.compareKey(base: set.baseCommit))
        }
    }

    // MARK: Hosting

    /// The app's view settings (`UserDefaults.app`): what hosted views read and write through
    /// `@AppStorage`, and the library's sort order. Emptied by `resetDefaults()`, so a test sees neither
    /// an earlier test's compare mode, layout or sort nor the user's.
    ///
    /// A plist in this process's `home`, never in ~/Library/Preferences: the user's defaults are shared
    /// by every process, so a run in another checkout at the same time would otherwise reset or set them
    /// in the middle of this one's snapshots.
    static let defaults: UserDefaults = {
        _ = home                                        // names the suite before the app first reads it
        precondition(UserDefaults.app !== UserDefaults.standard,
                     "UserDefaults.app was read before AppFixtures.home chose the tests' suite")
        return .app
    }()
    private static var defaultsSuite: String { home.appendingPathComponent("defaults").path }

    static func resetDefaults() {
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    /// Shows `view` in an off-screen window, as the app's window would, lets it settle, hands the hosting
    /// view to `body` and closes the window.
    ///
    /// - Parameter keepFocus: keep whichever field took focus (the ⌘K palette's search field
    ///   should); otherwise focus is cleared, as a field that took it while the view settled
    ///   draws a pixel off and the moment it arrives varies from run to run.
    static func host<V: View, Result>(_ view: V, size: CGSize = CGSize(width: 1100, height: 700),
                                      appearance: NSAppearance.Name = .aqua, keepFocus: Bool = false,
                                      _ body: (NSView) throws -> Result) rethrows -> Result {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // Rendering the hosting view skips the window's own background, which left headers
        // transparent (white text on white in dark mode); draw it as the window would.
        let hosting = NSHostingView(rootView: deterministic(view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))))
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        settle(hosting)
        if !keepFocus {
            window.makeFirstResponder(nil)
            settle(hosting)
        } else if let editor = window.firstResponder as? NSTextView {
            // The caret blinks, so a render caught it on or off by chance; leave it out.
            editor.insertionPointColor = .clear
            settle(hosting)
        }
        return try body(hosting)
    }

    private static func deterministic<V: View>(_ view: V) -> some View {
        view
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
            .environment(\.calendar, Calendar(identifier: .gregorian))
            .defaultAppStorage(defaults)
    }

    /// Lets SwiftUI finish layout and `onAppear`/`task` work that is already cached.
    static func settle(_ view: NSView) {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    // MARK: Models

    /// One directory per test process for settings, history, view settings and repositories. Those of
    /// earlier runs are removed once their process has ended, so runs don't pile up temp directories.
    ///
    /// Made once, it also isolates the process: the app's settings, history and patch registry
    /// (`SNAPSHOTKIT_HOME`) and view settings (`SNAPSHOTKIT_DEFAULTS`) go here instead of the user's,
    /// and git ignores the user's and the system's configuration (hooks, templates or signing would
    /// change what the tests see). Set here and only here: the environment is the whole process's,
    /// read by other threads meanwhile, and the core tests running alongside read it too.
    static let home: URL = {
        let runs = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-app-test-runs")
        for old in (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? [] {
            if let pid = Int32(old), pid != getpid(), kill(pid, 0) == 0 { continue }
            try? FileManager.default.removeItem(at: runs.appendingPathComponent(old))
        }
        let home = runs.appendingPathComponent("\(getpid())")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SNAPSHOTKIT_HOME", home.path, 1)
        setenv("SNAPSHOTKIT_DEFAULTS", home.appendingPathComponent("defaults").path, 1)
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        return home
    }()

    /// A fresh directory for one test's files.
    static func temporaryDirectory(_ name: String) -> URL {
        home.appendingPathComponent("\(name)-\(UUID().uuidString)").resolvingSymlinksInPath()
    }

    static func store() -> ProjectStore {
        try? FileManager.default.removeItem(at: home.appendingPathComponent("settings.json"))
        let store = ProjectStore(url: home.appendingPathComponent("settings.json"))
        store.update { s in
            s.discovered = ["/work/SampleApp", "/work/design-system", "/work/onboarding-flow", "/work/payments-ui"]
            s.pinned = ["/work/design-system"]
            s.recents = ["/work/SampleApp"]
        }
        return store
    }

    enum Scenario { case library, manyVariants, failedRun, running, changes, failures, empty, missingXcode, brokenConfig, missingBaseBranch, neverRun }

    /// How payButton.dark.png evolved: recorded, restyled, then re-recorded.
    static let snapshotVersions = [
        SnapshotVersion(commit: "3f1c2a9d0e7b6c5a4f3e2d1c0b9a8f7e6d5c4b3a", author: "Ana", date: date.addingTimeInterval(-2 * 86_400),
                        subject: "Re-record checkout snapshots"),
        SnapshotVersion(commit: "9b8a7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b", author: "Sam", date: date.addingTimeInterval(-20 * 86_400),
                        subject: "Use the new button style"),
        SnapshotVersion(commit: "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b", author: "Ana", date: date.addingTimeInterval(-60 * 86_400),
                        subject: "Add checkout snapshot tests"),
    ]

    /// A small library: two modules, light and dark variants, one re-recorded and one new snapshot.
    static let libraryImages: [(SnapshotFile, Data)] = [
        (SnapshotFile(path: "\(snapshotDir)/CheckoutViewTests/payButton.dark.png", byteSize: 48_210), screen(accent: .systemIndigo)),
        (SnapshotFile(path: "\(snapshotDir)/CheckoutViewTests/payButton.light.png", byteSize: 51_870), reference),
        (SnapshotFile(path: "\(snapshotDir)/CheckoutViewTests/summary.1.png", byteSize: 39_402, state: .modified), renderingNoise),
        (SnapshotFile(path: "\(snapshotDir)/ProfileViewTests/badge.1.png", byteSize: 22_118, state: .untracked), badged),
        (SnapshotFile(path: "\(snapshotDir)/ProfileViewTests/header.1.png", byteSize: 30_664), screen(accent: .systemTeal, titleWidth: 0.8)),
        // Its test was removed; nothing records or checks it any more.
        (SnapshotFile(path: "\(snapshotDir)/ProfileViewTests/oldAvatar.1.png", byteSize: 28_930), screen(accent: .systemGray)),
        (SnapshotFile(path: "Modules/DesignSystem/Tests/DesignSystemSnapshotTests/__Snapshots__/ButtonTests/primary.1.png", byteSize: 12_032),
         screen(accent: .systemPink, titleWidth: 0.3)),
    ]

    /// `remoteHost`: a remote machine to run on; the screenshots show the field's placeholder instead.
    static func project(_ scenario: Scenario, store: ProjectStore, remoteHost: String? = nil) -> ProjectModel {
        let model = ProjectModel(project: Project(path: repository.path), store: store, autoload: false)
        let tmp = temporaryDirectory("fixtures")
        var f = ProjectFixture()
        f.context = context(at: repository, remoteHost: remoteHost)
        f.environment = environment
        f.modules = ["AppSnapshotTests", "DesignSystemSnapshotTests"]
        f.currentBranch = "feature/checkout-redesign"
        f.changeSet = changeSet
        f.changeImages = Dictionary(uniqueKeysWithValues: changes.map { ($0.0.path, ($0.1, $0.2)) })
        func add(_ images: [(SnapshotFile, Data)]) {
            for (file, data) in images {
                f.snapshotImages[file.path] = data
                ThumbnailCache.preload(id: "snapshot:" + file.cacheKey, data: data)
                ThumbnailCache.preload(id: "snapshot:" + file.cacheKey, data: data, size: SnapshotGrid.tile)
                if let entry = SnapshotImageCache.Entry(data: data) { SnapshotImageCache.store(entry, for: file.cacheKey) }
            }
        }
        add(libraryImages)
        f.library = SnapshotLibrary(files: libraryImages.map(\.0))
        f.orphanIDs = ["\(snapshotDir)/ProfileViewTests/oldAvatar.1.png"]
        let payButton = libraryImages[0].0.path
        f.history[payButton] = snapshotVersions
        f.versionImages[snapshotVersions[2].commit + ":" + payButton] = screen(accent: .systemIndigo, titleWidth: 0.45)
        f.failingSuites = [checkoutSuite, profileSuite]
        f.failures = failures(in: tmp)
        f.failureSource = FailureSource(label: "Last run", date: date, host: "local")
        f.historyFlaky = [f.failures[0].historyFlaky!]
        warmChangeCaches()

        switch scenario {
        case .library:
            f.tab = .snapshots
        case .manyVariants:
            f.tab = .snapshots
            // payButton in light and dark at three text sizes: more variants than fit side by side.
            let sizes = ["large-dark", "large-light", "xl-dark", "xl-light"].map {
                (SnapshotFile(path: "\(snapshotDir)/CheckoutViewTests/payButton.\($0).png", byteSize: 50_000),
                 screen(accent: $0.hasSuffix("dark") ? .systemIndigo : .systemBlue, titleWidth: 0.7))
            }
            add(sizes)
            f.library = SnapshotLibrary(files: libraryImages.map(\.0) + sizes.map(\.0))
        case .failedRun:
            f.tab = .run
            f.passed = 1
            f.failed = 2
            f.log = log
            f.lastResult = lastResult
            f.lastMessage = ProjectModel.failureTitle(tests: 2, suites: 2)
            f.lastMessageIsError = true
            f.lastMessageAction = .showFailures
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
            // Mid-review: one snapshot already looked at.
            f.viewedChanges = [changes[3].0.id]
        case .failures:
            f.tab = .failures
        case .missingXcode:
            f.tab = .run
            f.context = context(at: repository, xcode: "99.2", remoteHost: remoteHost) // what CI asks for, which this Mac lacks
            f.environment = nil
            f.environmentError = EnvironmentError.xcodeNotInstalled(
                required: "99.2", source: ".gitlab-ci.yml",
                installed: [XcodeInstall(path: "/Applications/Xcode.app", version: "99.1")]).errorDescription
            // Failing suites from an earlier run stay: only running them needs Xcode.
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
            f.library = SnapshotLibrary(files: [])
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
