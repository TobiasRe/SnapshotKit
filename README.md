# SnapshotKit

A macOS app (and `snapkit` CLI) for dealing with failing and flaky iOS snapshot tests built with
[swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing):

- **Run** a module's snapshot tests with exactly the configuration your CI uses, with live output and pass/fail counts.
- **Re-record** only the failing suites, then verify the new references.
- **Investigate failures**: reference vs. actual vs. difference, also for a `.xcresult` downloaded from CI.
- **Tell flaky from broken**: rerun failing tests N times; run history flags tests that both passed and failed on the same commit.
- **Run on a CI machine** over SSH, to reproduce failures that only happen there.
- **Review changes**: every PNG that differs from the base branch, grouped by suite, with side-by-side, slider and pixel-diff views.

Requires macOS 14+ and Xcode 16 or later (for `xcresulttool get test-results`).

## Quick start

```bash
scripts/make-app.sh          # builds dist/SnapshotKit.app and dist/snapkit
open dist/SnapshotKit.app
```

Add a repository (⌘O) or a folder to scan (sidebar **+** › Add Scan Folder). Then:

| | |
|---|---|
| ⌘R | Run snapshot tests |
| ⇧⌘R | Re-record failed suites |
| ⌥⌘R | Check flakiness of failed tests |
| ⌃⌘R | Run on the remote machine |
| ⌘. | Cancel |
| ⇧⌘O | Import an `.xcresult` (e.g. a CI artifact) |
| ⌘K | Quick switch project |
| ⌘= / ⌘− / ⌘0 | Zoom in / out / fit. Pinch to zoom, two-finger or mouse drag to pan, double-click to reset |

The same features are on the command line:

```bash
snapkit config            # show the resolved configuration and where each value came from
snapkit run               # run like CI; exits 1 on failures and names failing suites
snapkit rerecord          # re-record the last run's failing suites and verify
snapkit flaky --iterations 10
snapkit failures --xcresult ~/Downloads/ci.xcresult
snapkit changes --filter dark
snapkit run --remote      # on the machine in remoteHost
```

## Configuration

SnapshotKit reads `.gitlab-ci.yml` (plus local `include:` files), `.github/workflows/*.yml`, and shell
scripts those call. From the `xcodebuild … test` invocation that looks most like a snapshot job, it takes
`-scheme`, `-workspace`/`-project`, `-testPlan`, `-destination` (device and OS), `-only-testing` and
`-skip-testing`, plus a preceding `cd`. Variables (`$VAR`, `${VAR}`, `${{ env.VAR }}`) are expanded.
The Xcode version comes from `xcode-version:`, `Xcode_X.Y.app` paths, `*XCODE*VERSION*` variables,
`xcodes select`, or image tags. The base branch comes from the MR/PR target branch, or else from `origin/HEAD`
(falling back to `develop`/`main`/`master`).

If Xcode or the simulator is missing, you get an error saying what is required, by which file, what is installed, and how to fix it.

Anything can be overridden in `.snapshotkit.yml` at the repository root:

```yaml
xcode: "<version>"          # or developerDir: /Applications/Xcode.app
device: <simulator name>
os: "<iOS version>"         # or latest
scheme: App
workspace: App.xcworkspace  # or project: App.xcodeproj
testPlan: SnapshotTests
onlyTesting: [AppSnapshotTests]
skipTesting: []
baseBranch: develop
workingDirectory: .
extraArguments: -configuration Debug
remoteHost: ci-mac-1        # SSH host or ~/.ssh/config alias
remoteDirectory: ~/snapshotkit/app
```

Per-project settings in the app (base branch, remote host, module) override both. App settings are stored as
JSON in `~/Library/Application Support/SnapshotKit/` (`SNAPSHOTKIT_HOME` overrides the location).

## How re-record works

1. The failing suites come from the last run (`.git/snapshotkit/last-run.json`, shared by the app and CLI).
   If there is no last run, the tests run first.
2. SnapshotKit finds each suite's source file (from the failure location, or by searching for its declaration).
   It **refuses** to continue if any of those files has uncommitted changes.
3. It writes a journal with the original contents to `.git/snapshotkit/record-patch.json`, then patches the record trait:
   - Swift Testing: `@Suite(.snapshots(record: .all))` (it adds the attribute or trait, or replaces an existing `record:` value).
   - XCTest: an `invokeTest()` override wrapping the test in `withSnapshotTesting(record: .all)`.
4. It runs only those suites (`-only-testing:Target/Suite`), then restores the files. It then runs the suites again
   without the patch to verify the new references.

The patch is always undone: on success, error, cancel, Ctrl-C, `SIGTERM`/`SIGHUP` (child `xcodebuild` is stopped
first), and app quit. If the process is killed outright, the next launch of the app or any `snapkit` command restores it.
If a patched file was edited during the run, only SnapshotKit's change is removed and your edits are kept. If that is
impossible, the file is left alone, the original is saved under `.git/snapshotkit/backups/`, and you get a warning.

## Remote runs

With `remoteHost` set, SnapshotKit uses key-based SSH (it never asks for passwords) and does the following:

1. Checks that the remote has the Xcode and simulator CI expects.
2. Rsyncs the working tree (tracked and untracked, not ignored files) to a cache directory.
3. Runs the same `xcodebuild` command there with streamed output. Cancelling stops the remote run.
4. Brings back the results and failure images.

**Re-record on remote** patches only the remote copy and downloads the newly recorded PNGs into your working tree,
so you get references rendered on the CI machine. `remoteHost: local` uses a local directory instead of SSH,
which is handy for trying the workflow out.

## Development

```bash
swift test                              # core unit tests + the app's own snapshot tests
scripts/e2e.sh [--keep]                 # end to end against a real simulator (sample package, ~10 min)
scripts/capture-ui.sh <repo> [out-dir]  # headless full-window screenshots of every view
```

The app's UI is covered by snapshot tests (swift-snapshot-testing with Swift Testing) in
`Tests/SnapshotKitAppTests`. They render real views from fixture state in light and dark. Liquid Glass
can't be composited off-screen, so those renders use an opaque stand-in and leave out the system toolbar
and sidebar chrome. To update references, delete the PNG or set `record: .all`, or re-record them with
SnapshotKit itself. Visual guidelines are in [docs/DESIGN.md](docs/DESIGN.md).

`SnapshotKitCore` holds all the logic: config, process runner, xcresult parser, git, record-patch manager,
remote runner and project store. `SnapshotKit` (SwiftUI) and `snapkit` are thin front ends.
`SnapshotKit --capture out.png --project <repo> --tab changes --compare slider --zoom 3` renders the window
off-screen without activating the app.

## License

MIT, see [LICENSE](LICENSE).
