import Foundation
import Testing
@testable import SnapshotKitCore

/// `snapkit` as docs/cli.md describes it: the built executable against temporary repositories,
/// output and exit status compared in full. Nothing here needs Xcode or a simulator.
@Suite(.isolated) struct CLIUsageTests {
    let snapkit = Snapkit()

    @Test(arguments: [[], ["help"], ["-h"], ["--help"]])
    func helpListsEveryCommand(_ arguments: [String]) throws {
        let result = try snapkit.run(arguments)
        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.hasPrefix("usage: snapkit <command> [options]\n"))
        // A command's line starts with two spaces; its continuation lines with more.
        let listed = result.stdout.split(separator: "\n")
            .filter { $0.hasPrefix("  ") && !$0.hasPrefix("   ") }
            .compactMap { $0.split(separator: " ").first.map(String.init) }
        // Every command of docs/cli.md's table, in the usage text's order.
        #expect(listed == ["snapshots", "record", "config", "run", "rerecord", "flaky", "failures", "changes", "history",
                           "restore", "diff", "open", "projects"])
    }

    @Test(arguments: ["version", "--version", "-v"])
    func versionPrintsTheRelease(_ argument: String) throws {
        #expect(Outcome(try snapkit(argument)) == Outcome(status: 0, stdout: "snapkit \(SnapshotKitVersion.current)\n"))
    }

    struct UsageCase: Sendable, CustomTestStringConvertible {
        var arguments: [String]
        var message: String
        var testDescription: String { arguments.joined(separator: " ") }
    }

    /// "An option the command doesn’t take, a missing or malformed value, or an extra argument is
    /// an error (exit status 64)." `REPO` stands for a repository the case gets of its own.
    @Test(arguments: [
        UsageCase(arguments: ["bogus"], message: "unknown command 'bogus'"),
        UsageCase(arguments: ["snapshots", "--verbose"], message: "snapkit snapshots: unknown option --verbose"),
        UsageCase(arguments: ["snapshots", "--filter"], message: "snapkit snapshots: --filter needs a value"),
        UsageCase(arguments: ["snapshots", "extra"], message: "snapkit snapshots: unexpected argument 'extra'"),
        UsageCase(arguments: ["run", "--repo", "--verbose"], message: "snapkit run: --repo needs a value"),
        UsageCase(arguments: ["history", "A/B/a()", "A/B/b()"], message: "snapkit history: unexpected argument 'A/B/b()'"),
        UsageCase(arguments: ["diff", "a.png"], message: "usage: snapkit diff A.png B.png [-o OUT.png]"),
        UsageCase(arguments: ["diff", "a.png", "b.png", "c.png"], message: "usage: snapkit diff A.png B.png [-o OUT.png]"),
        UsageCase(arguments: ["open", "a.png"], message: "usage: snapkit open REFERENCE.png ACTUAL.png [--app PATH]"),
        UsageCase(arguments: ["record"], message: "usage: snapkit record TEXT… (part of a snapshot path, e.g. a test or suite name)"),
        UsageCase(arguments: ["projects", "bogus"], message: "usage: snapkit projects scan ROOT... | list"),
        UsageCase(arguments: ["projects", "list", "extra"], message: "usage: snapkit projects scan ROOT... | list"),
        UsageCase(arguments: ["projects", "scan"], message: "usage: snapkit projects scan ROOT..."),
        UsageCase(arguments: ["snapshots", "--repo", "REPO", "--sort", "name"], message: "--sort takes size or recent, not 'name'"),
        UsageCase(arguments: ["run", "--repo", "REPO", "--iterations", "1"], message: "--iterations needs a whole number of at least 2, not '1'"),
        UsageCase(arguments: ["run", "--repo", "REPO", "--iterations", "many"], message: "--iterations needs a whole number of at least 2, not 'many'"),
        // Before looking for failing suites: without a last run, that means running every test first.
        UsageCase(arguments: ["flaky", "--repo", "REPO", "--iterations", "1"], message: "--iterations needs a whole number of at least 2, not '1'"),
        UsageCase(arguments: ["rerecord", "--repo", "REPO", "--suite", "CardTests"],
                  message: "--suite CardTests: name its test target too, as in --suite AppTests/CardTests"),
    ])
    func wrongArgumentsExitWith64(_ usage: UsageCase) throws {
        var arguments = usage.arguments
        if let i = arguments.firstIndex(of: "REPO") {
            let repo = try TempRepo()
            try repo.write("README.md", "x")
            try repo.commitAll("init")
            arguments[i] = repo.url.path
        }
        #expect(Outcome(try snapkit.run(arguments)) == usageFailure(usage.message))
    }
}

@Suite(.isolated) struct CLIRepositoryTests {
    let snapkit = Snapkit()

    @Test func aFolderThatDoesNotExist() throws {
        #expect(Outcome(try snapkit("snapshots", "--repo", "/no/such/folder")) == failure("no such folder: /no/such/folder"))
    }

    @Test func aFolderOutsideARepository() throws {
        let plain = testTemp("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(Outcome(try snapkit("snapshots", "--repo", plain.path)) == failure("\(plain.path) is not inside a git repository"))
        // The current directory, as the process sees it.
        let cwd = String(cString: realpath(plain.path, nil))
        #expect(Outcome(try snapkit("changes", in: plain)) == failure("\(cwd) is not inside a git repository"))
    }

    @Test func withoutGit() throws {
        let repo = try TempRepo()
        #expect(Outcome(try snapkit("snapshots", "--repo", repo.url.path, environment: ["PATH": "/no/such/bin"]))
                == failure("`git` was not found on the PATH (/no/such/bin). Install Xcode or its command line tools (`xcode-select --install`)."))
    }

    /// "Any folder inside a repository works": paths are the repository's, from its root.
    @Test func anyFolderInsideTheRepository() throws {
        let repo = try TempRepo()
        try repo.write("Tests/AppTests/__Snapshots__/CardTests/card.1.png", Data(count: 10))
        try repo.commitAll("init")
        let expected = try snapkit("snapshots", "--repo", repo.url.path)
        #expect(expected.status == 0 && expected.stdout.hasPrefix("Tests/AppTests/__Snapshots__/CardTests/card.1.png  "))
        #expect(Outcome(try snapkit("snapshots", in: repo.url.appendingPathComponent("Tests/AppTests"))) == Outcome(expected))
        #expect(Outcome(try snapkit("snapshots", "--repo", repo.url.appendingPathComponent("Tests").path)) == Outcome(expected))
    }
}

@Suite(.isolated) struct CLISnapshotsTests {
    let snapkit = Snapkit()
    let dir = "Tests/AppTests/__Snapshots__/CardTests"

    /// compact (1000 bytes, clean), expanded.1 (3000, modified), expanded.2 (2000, new) and
    /// gone (500, its test was deleted); modified longest ago in that order: gone, expanded.1,
    /// expanded.2, compact.
    func makeRepo() throws -> TempRepo {
        let repo = try TempRepo()
        try repo.write("Tests/AppTests/CardTests.swift", """
            import Testing
            @Suite struct CardTests {
                @Test func compact() {}
                @Test func expanded() {}
            }
            """)
        try repo.write("Sources/App/logo.png", Data(count: 4000))
        try repo.write("\(dir)/compact.1.png", Data(count: 1000))
        try repo.write("\(dir)/expanded.1.png", Data(count: 100))
        try repo.write("\(dir)/gone.1.png", Data(count: 500))
        try repo.commitAll("init")
        try repo.write("\(dir)/expanded.1.png", Data(count: 3000))
        try repo.write("\(dir)/expanded.2.png", Data(count: 2000))
        for (name, age) in [("gone.1.png", 40.0), ("expanded.1.png", 30), ("expanded.2.png", 20), ("compact.1.png", 10)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                                  ofItemAtPath: repo.url.appendingPathComponent("\(dir)/\(name)").path)
        }
        return repo
    }

    func line(_ name: String, _ size: Int, _ mark: String? = nil) -> String {
        "\(dir)/\(name)  \(SnapshotLibrary.formatSize(size))" + (mark.map { "  " + $0 } ?? "") + "\n"
    }

    func summary(_ shown: Int, tests: Int, bytes: Int) -> String {
        "\(shown) of 4 snapshots · \(tests) test\(tests == 1 ? "" : "s") · \(SnapshotLibrary.formatSize(bytes)) · 1 orphaned (`--orphans` lists them)\n"
    }

    @Test func listsEverySnapshotWithItsSizeAndState() throws {
        let repo = try makeRepo()
        let status = try repo.git.run(["status", "--porcelain"])
        #expect(Outcome(try snapkit("snapshots", "--repo", repo.url.path)) == Outcome(status: 0, stdout:
            line("compact.1.png", 1000) + line("expanded.1.png", 3000, "modified") + line("expanded.2.png", 2000, "new")
            + line("gone.1.png", 500, "orphaned") + summary(4, tests: 3, bytes: 6500)))
        #expect(try repo.git.run(["status", "--porcelain"]) == status) // read-only
    }

    @Test func filterKeepsPathsWithEveryWordInAnyCase() throws {
        let repo = try makeRepo()
        #expect(Outcome(try snapkit("snapshots", "--repo", repo.url.path, "--filter", "EXPANDED card")) == Outcome(status: 0, stdout:
            line("expanded.1.png", 3000, "modified") + line("expanded.2.png", 2000, "new") + summary(2, tests: 1, bytes: 5000)))
        // Repeating an option keeps its last value.
        #expect(Outcome(try snapkit("snapshots", "--filter", "compact", "--repo", repo.url.path, "--filter", "gone"))
                == Outcome(status: 0, stdout: line("gone.1.png", 500, "orphaned") + summary(1, tests: 1, bytes: 500)))
    }

    @Test func orphansOnly() throws {
        let repo = try makeRepo()
        #expect(Outcome(try snapkit("snapshots", "--repo", repo.url.path, "--orphans"))
                == Outcome(status: 0, stdout: line("gone.1.png", 500, "orphaned") + summary(1, tests: 1, bytes: 500)))
    }

    @Test func sortedBySizeOrByModificationDate() throws {
        let repo = try makeRepo()
        let total = summary(4, tests: 3, bytes: 6500)
        #expect(Outcome(try snapkit("snapshots", "--repo", repo.url.path, "--sort", "size")) == Outcome(status: 0, stdout:
            line("expanded.1.png", 3000, "modified") + line("expanded.2.png", 2000, "new") + line("compact.1.png", 1000)
            + line("gone.1.png", 500, "orphaned") + total))
        #expect(Outcome(try snapkit("snapshots", "--repo", repo.url.path, "--sort", "recent")) == Outcome(status: 0, stdout:
            line("compact.1.png", 1000) + line("expanded.2.png", 2000, "new") + line("expanded.1.png", 3000, "modified")
            + line("gone.1.png", 500, "orphaned") + total))
    }

    @Test func aRepositoryWithoutSnapshots() throws {
        let repo = try TempRepo()
        #expect(Outcome(try snapkit("snapshots", "--repo", repo.url.path))
                == Outcome(status: 0, stdout: "0 of 0 snapshots · 0 tests · \(SnapshotLibrary.formatSize(0))\n"))
    }
}

@Suite(.isolated) struct CLIChangesTests {
    let snapkit = Snapkit()
    let red = png(width: 2, height: 2, rgba: (255, 0, 0, 255))
    let blue = png(width: 2, height: 2, rgba: (0, 0, 255, 255))
    let snaps = "Tests/AppTests/__Snapshots__"

    /// On `feature`: a committed and an uncommitted change, a deleted and a new snapshot; and
    /// `develop` moved on after the branch left it.
    func makeRepo() throws -> TempRepo {
        let repo = try TempRepo()
        for name in ["CardTests/a.1.png", "CardTests/b.1.png", "ListTests/c.1.png", "ListTests/e.1.png"] {
            try repo.write("\(snaps)/\(name)", red)
        }
        try repo.commitAll("base")
        try repo.git.run(["checkout", "-q", "-b", "feature"])
        try repo.write("\(snaps)/CardTests/a.1.png", blue)
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("\(snaps)/ListTests/c.1.png"))
        try repo.commitAll("feature")
        try repo.git.run(["checkout", "-q", "develop"])
        try repo.write("\(snaps)/ListTests/e.1.png", blue)
        try repo.commitAll("develop moved")
        try repo.git.run(["checkout", "-q", "feature"])
        try repo.write("\(snaps)/CardTests/b.1.png", blue)
        try repo.write("\(snaps)/ListTests/d.1.png", blue)
        return repo
    }

    @Test func groupsTheChangesSinceTheMergeBaseByFolder() throws {
        let repo = try makeRepo()
        let base = try repo.git.run(["merge-base", "develop", "HEAD"])
        #expect(Outcome(try snapkit("changes", "--repo", repo.url.path)) == Outcome(status: 0, stdout: """
            Snapshots changed vs develop (Merge-base \(base.prefix(8))): 4
            CardTests
              Committed    \(snaps)/CardTests/a.1.png
              Uncommitted  \(snaps)/CardTests/b.1.png
            ListTests
              Deleted      \(snaps)/ListTests/c.1.png
              New          \(snaps)/ListTests/d.1.png

            """))
        #expect(Outcome(try snapkit("changes", "--repo", repo.url.path, "--filter", "list D")) == Outcome(status: 0, stdout: """
            Snapshots changed vs develop (Merge-base \(base.prefix(8))): 1
            ListTests
              New          \(snaps)/ListTests/d.1.png

            """))
    }

    /// The tip has `develop`’s own change too (as a committed one: the diff runs from there to
    /// HEAD); `origin/develop` wins over the local branch.
    @Test func againstTheTipOfTheRemoteBranch() throws {
        let repo = try makeRepo()
        let tip = try repo.git.run(["rev-parse", "develop"])
        try repo.git.run(["update-ref", "refs/remotes/origin/develop", "develop"])
        let changes = Outcome(try snapkit("changes", "--repo", repo.url.path, "--tip", "--filter", "ListTests"))
        #expect(changes == Outcome(status: 0, stdout: """
            Snapshots changed vs origin/develop (Branch tip \(tip.prefix(8))): 3
            ListTests
              Deleted      \(snaps)/ListTests/c.1.png
              New          \(snaps)/ListTests/d.1.png
              Committed    \(snaps)/ListTests/e.1.png

            """))
    }

    @Test func nothingToCompareWith() throws {
        let repo = try makeRepo()
        #expect(Outcome(try snapkit("changes", "--repo", repo.url.path, "--base", "nope"))
                == failure("Base branch “nope” was not found locally or on origin. Fetch it or choose a different base branch."))

        let empty = try TempRepo()
        #expect(Outcome(try snapkit("changes", "--repo", empty.url.path)) == failure("No base branch; pass --base BRANCH"))
        #expect(Outcome(try snapkit("changes", "--repo", empty.url.path, "--base", "develop"))
                == failure("This repository has no commits yet, so there is nothing to compare with."))

        let trunk = try TempRepo(branch: "trunk")
        try trunk.write("README.md", "x")
        try trunk.commitAll("init")
        #expect(Outcome(try snapkit("changes", "--repo", trunk.url.path)) == failure("No base branch; pass --base BRANCH"))
    }
}

@Suite(.isolated) struct CLIConfigTests {
    let snapkit = Snapkit()

    func rows(baseBranch: String = "develop  (git (auto-detected))") -> String {
        """
          xcode          —
          developerDir   /no/such/Xcode.app  (.snapshotkit.yml)
          device         Example Phone  (.snapshotkit.yml)
          os             99.0  (.snapshotkit.yml)
          scheme         App  (.snapshotkit.yml)
          workspace      —
          project        —
          testPlan       —
          onlyTesting    —
          baseBranch     \(baseBranch)
          workingDir     —
          remoteHost     —
          modules        —
        note: No .gitlab-ci.yml or .github/workflows found; using .snapshotkit.yml only.

        """
    }

    func makeRepo() throws -> TempRepo {
        let repo = try TempRepo()
        try repo.write(".snapshotkit.yml", "scheme: App\ndevice: Example Phone\nos: \"99.0\"\ndeveloperDir: /no/such/Xcode.app\n")
        try repo.commitAll("init")
        return repo
    }

    /// Every value with its source, then the Xcode check: exit 2 when Xcode isn't there.
    @Test func printsEveryValueWithItsSourceAndChecksXcode() throws {
        let repo = try makeRepo()
        #expect(Outcome(try snapkit("config", "--repo", repo.url.path)) == failure(
            "Xcode at `/no/such/Xcode.app` does not exist. Install it there or set `xcode:` / `developerDir:` in `.snapshotkit.yml`.", status: 2,
            stdout: "Repository: \(repo.root)\nCI files:   none\nOverride:   .snapshotkit.yml\n" + rows()))
    }

    /// The app's per-project settings come last, and win.
    @Test func projectSettingsWin() throws {
        let repo = try makeRepo()
        snapkit.settings.updateSettings(for: Project(path: repo.root)) { $0.baseBranch = "trunk"; $0.remoteHost = "ci-mac" }
        let result = try snapkit("config", "--repo", repo.url.path)
        #expect(result.status == 2)
        #expect(result.stdout == "Repository: \(repo.root)\nCI files:   none\nOverride:   .snapshotkit.yml\n"
                + rows(baseBranch: "trunk  (project setting)").replacingOccurrences(of: "remoteHost     —", with: "remoteHost     ci-mac  (project setting)"))
    }

    @Test func anUnreadableOverrideFileExits1() throws {
        let repo = try TempRepo()
        let text = "scheme:\n  name: App\n"
        try repo.write(".snapshotkit.yml", text)
        let parseError = try #require(throws: (any Error).self) { try MiniYAML.parse(text) }
        let expected = ConfigError.invalidOverride(parseError.localizedDescription).errorDescription!
        #expect(expected == "`.snapshotkit.yml` could not be read (line 2: nested mappings are not supported).")
        #expect(Outcome(try snapkit("config", "--repo", repo.url.path)) == failure(expected))
        // Every command that reads the configuration says so.
        #expect(Outcome(try snapkit("history", "--repo", repo.url.path)) == failure(expected))
    }

    /// Exit 2 before anything runs, and nothing is recorded.
    @Test func runWithoutTheConfiguredXcode() throws {
        let repo = try makeRepo()
        #expect(Outcome(try snapkit("run", "--repo", repo.url.path)) == failure(
            "Xcode at `/no/such/Xcode.app` does not exist. Install it there or set `xcode:` / `developerDir:` in `.snapshotkit.yml`.", status: 2))
        #expect(snapkit.history(of: repo.url).load().isEmpty)
        #expect(LastRun.load(repository: repo.url) == nil)
    }
}

@Suite(.isolated) struct CLIImageTests {
    let snapkit = Snapkit()

    /// 10×10 white, with the first `painted` pixels in `color`.
    func image(painted: Int = 0, color: (UInt8, UInt8, UInt8) = (255, 0, 0), base: (UInt8, UInt8, UInt8) = (255, 255, 255),
               width: Int = 10) -> PixelImage {
        var pixels: [UInt8] = []
        for i in 0..<(width * 10) {
            let c = i < painted ? color : base
            pixels += [c.0, c.1, c.2, 255]
        }
        return PixelImage(width: width, height: 10, pixels: pixels)
    }

    func file(_ name: String, _ image: PixelImage) throws -> URL {
        let url = testTemp(name).appendingPathExtension("png")
        try image.pngData()!.write(to: url)
        return url
    }

    @Test func identicalImagesExit0() throws {
        let a = try file("a", image()), b = try file("b", image())
        #expect(Outcome(try snapkit("diff", a.path, b.path)) == Outcome(status: 0, stdout: "identical\n"))
    }

    @Test func aVisibleChangeExits1AndWritesTheDifference() throws {
        let a = try file("a", image()), b = try file("b", image(painted: 3))
        let out = testTemp("diff").appendingPathExtension("png")
        let delta = String(format: "%.1f", ImageDiff.compare(image(), image(painted: 3)).maxPerceptualDelta)
        #expect(Outcome(try snapkit("diff", a.path, b.path, "-o", out.path))
                == Outcome(status: 1, stdout: "3 pixels differ (3.000%), largest ΔE \(delta)\nVisible change in a 3×1 area at 0, 0.\n"))
        let written = try #require(PixelImage(data: try Data(contentsOf: out)))
        #expect((written.width, written.height) == (10, 10))
        #expect(written.color(x: 2, y: 0)?.hex == "#FF00FF")   // changed pixels in magenta
        #expect(written.color(x: 3, y: 0)?.hex != "#FF00FF")
    }

    @Test func invisibleNoiseSaysWhichPrecisionPasses() throws {
        let a = try file("a", image(base: (200, 200, 200))), b = try file("b", image(base: (201, 200, 199)))
        let delta = String(format: "%.1f", ImageDiff.compare(image(base: (200, 200, 200)), image(base: (201, 200, 199))).maxPerceptualDelta)
        #expect(Outcome(try snapkit("diff", a.path, b.path)) == Outcome(status: 1, stdout: """
            100 pixels differ (100.000%), largest ΔE \(delta)
            No visible difference (largest ΔE \(delta)), typical of rendering on another machine or OS version.
            Would pass with: perceptualPrecision: 0.99

            """))
    }

    @Test func aDifferentSizeSaysSo() throws {
        let a = try file("a", image()), b = try file("b", image(width: 12))
        #expect(Outcome(try snapkit("diff", a.path, b.path)) == Outcome(status: 1, stdout: """
            20 pixels differ (16.667%), size changed, largest ΔE 0.0
            The image size changed, so the device, scale or layout differs from the reference.

            """))
    }

    @Test func unreadableImagesAndOutputsExit2() throws {
        let a = try file("a", image())
        let text = testTemp("notes").appendingPathExtension("png")
        try Data("not a png".utf8).write(to: text)
        #expect(Outcome(try snapkit("diff", a.path, text.path)) == failure("\(text.path) is not an image", status: 2))
        let missing = try snapkit("diff", "/no/such/a.png", a.path)
        #expect(missing.status == 2 && missing.stdout.isEmpty && missing.stderr.hasPrefix("error: "))
        let unwritable = try snapkit("diff", a.path, a.path, "-o", "/no/such/folder/out.png")
        #expect(unwritable.status == 2 && unwritable.stdout == "identical\n" && unwritable.stderr.hasPrefix("error: "))
    }

    /// The app isn't opened here: an app that doesn't exist can't be.
    @Test func openPrintsTheDiffThenNamesTheAppItCouldNotOpen() throws {
        let a = try file("a", image()), b = try file("b", image(painted: 3))
        let delta = String(format: "%.1f", ImageDiff.compare(image(), image(painted: 3)).maxPerceptualDelta)
        let summary = "3 pixels differ (3.000%), largest ΔE \(delta)\nVisible change in a 3×1 area at 0, 0.\n"
        let couldNotOpen = { (app: String) in
            failure("Couldn’t open SnapshotKit at \(app). Install SnapshotKit.app from https://github.com/TobiasRe/SnapshotKit/releases, or pass --app PATH.",
                    stdout: summary)
        }
        #expect(Outcome(try snapkit("open", a.path, b.path, "--app", "/no/such/SnapshotKit.app")) == couldNotOpen("/no/such/SnapshotKit.app"))
        #expect(Outcome(try snapkit("open", a.path, b.path, environment: ["SNAPSHOTKIT_APP": "/no/such/Dev.app"])) == couldNotOpen("/no/such/Dev.app"))
        // `--app` wins over the variable.
        #expect(Outcome(try snapkit("open", a.path, b.path, "--app", "/no/such/SnapshotKit.app", environment: ["SNAPSHOTKIT_APP": "/no/such/Dev.app"]))
                == couldNotOpen("/no/such/SnapshotKit.app"))
    }

    @Test func openNamesAMissingFile() throws {
        let a = try file("a", image())
        let dir = a.deletingLastPathComponent()
        #expect(Outcome(try snapkit("open", a.path, "missing.png", "--app", "/no/such/SnapshotKit.app", in: dir))
                == failure("no such file: \(String(cString: realpath(dir.path, nil)))/missing.png"))
    }
}

@Suite(.isolated) struct CLIProjectsTests {
    let snapkit = Snapkit()

    /// A folder with one repository with snapshots and one without.
    func makeFolder() throws -> (root: URL, project: String) {
        let root = testTemp("projects")
        for (name, snapshots) in [("app", true), ("lib", false)] {
            let git = Git(root: root.appendingPathComponent(name))
            try FileManager.default.createDirectory(at: git.root, withIntermediateDirectories: true)
            try git.run(["init", "-q"])
            if snapshots {
                let file = git.root.appendingPathComponent("Tests/__Snapshots__/A/a.1.png")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([1]).write(to: file)
                try git.run(["add", "-A"])
            }
        }
        return (root, Project(path: root.appendingPathComponent("app").path).path)
    }

    @Test func scanAddsTheFolderAndListsWhatItFound() throws {
        let (root, project) = try makeFolder()
        #expect(Outcome(try snapkit("projects", "scan", root.path))
                == Outcome(status: 0, stdout: "\(project)\n1 project(s) with snapshot tests (looked \(ProjectScanner.defaultDepth) folders deep).\n"))
        #expect(snapkit.settings.settings.scanRoots == [Project(path: root.path).path])
        #expect(Outcome(try snapkit("projects")) == Outcome(status: 0, stdout: "   \(project)\n"))

        snapkit.settings.togglePin(Project(path: project))
        snapkit.settings.markOpened(Project(path: "/no/such/recent"))
        #expect(Outcome(try snapkit("projects", "list")) == Outcome(status: 0, stdout: "📌 \(project)\n   /no/such/recent\n"))
    }

    /// The app reads the settings from its own working directory: a relative folder must not be kept.
    @Test func aRelativeFolderIsKeptAsAnAbsolutePath() throws {
        let (root, project) = try makeFolder()
        #expect(try snapkit("projects", "scan", ".", in: root).stdout.hasPrefix("\(project)\n"))
        #expect(snapkit.settings.settings.scanRoots == [Project(path: root.path).path])
    }

    /// Not reported as a folder macOS doesn't let it read, nor kept to be rescanned forever.
    @Test func aFolderThatDoesNotExistIsAnError() throws {
        #expect(Outcome(try snapkit("projects", "scan", "/no/such/folder")) == failure("no such folder: /no/such/folder"))
        #expect(snapkit.settings.settings.scanRoots.isEmpty)
    }
}
