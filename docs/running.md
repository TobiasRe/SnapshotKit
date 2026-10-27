# Running tests

SnapshotKit runs your snapshot tests **the way your CI runs them**: the same scheme, workspace, test plan,
test selection, simulator and, when it’s installed, the same Xcode version, all read from your CI files. That
way a test that passes in SnapshotKit passes in CI, and references recorded here match what CI compares.

## Starting a run

- **⌘R**, **Snapshots › Run Snapshot Tests**, the toolbar’s ▶, or **Run Tests** in Run.
- **⌘.** or **Cancel** stops it (the run is terminated and any record patch is restored). A canceled run
  says *Cancelled.* and leaves the last run’s failures as they were, as does a run whose build fails (*Build
  failed: …*).

**Run** (⌥⌘4, in the sidebar) shows the run as it happens:

- a header with the phase (*Preparing*, *Resolving packages*, *Building*, *Testing*, *Finished*) and a progress
  bar once the number of tests is known,
- live counts: passed, failed, skipped, and the test running now,
- the **Output**: the command line (`$ xcodebuild test …`), then the test log. By default the log shows the
  test lines; turn on **Build output** to see everything `xcodebuild` prints. Filter the output with the search
  field (matches are highlighted), copy it with the copy button.

When the run ends, the **Results** list shows every test by suite, with its outcome and duration, and an
arrow to jump to a failure. A notice offers **Show Failures** when something failed. The project’s failing
count appears in the sidebar, the Dock icon and the [menu bar item](menu-bar.md).

## The configuration panel

The left side of Run shows what SnapshotKit will run and where each value comes from:

| Section | Shows |
|---|---|
| **Environment** | the Xcode version (and build) that will be used, *Not pinned by CI* when CI doesn’t name one, and the simulator with its state (e.g. *Booted*). |
| **Scope** | **Test target**: *What CI runs* (default), or one test target with snapshots, to run only its tests. |
| **Configuration** | scheme, workspace or project, test plan, `-only-testing` selection and working directory. A footer names the CI files they come from; a value from somewhere else (*.snapshotkit.yml*, a script) names its source. Notes say what SnapshotKit had to guess or couldn’t read. Until Xcode and the simulator are found, it also shows the Xcode and device that were asked for. |
| **Comparison & Remote** | the **Base branch** for Working Copy and vs develop, and the **Remote host** for remote runs; type to override them for this project. |

When something is missing or wrong — Xcode not installed, no simulator runtime, a broken `.snapshotkit.yml` —
the inspector on the left says exactly what and how to fix it, and the header offers **Check Again**. See
[Troubleshooting](troubleshooting.md).

How the configuration is resolved, and every key of `.snapshotkit.yml`, is in [Configuration](configuration.md).

## The command SnapshotKit runs

```
xcodebuild test
  -workspace App.xcworkspace          (or -project App.xcodeproj)
  -scheme App
  -testPlan Snapshots                 (if configured)
  -destination 'platform=iOS Simulator,id=<udid>'
  -resultBundlePath .git/snapshotkit/results/<timestamp>.xcresult
  -only-testing:AppSnapshotTests      (if configured, or the chosen test target)
  -skip-testing:…                     (if configured)
  <extraArguments from .snapshotkit.yml>
  -collect-test-diagnostics never
```

- It runs in the repository (or its `workingDirectory`) with `DEVELOPER_DIR` set to the chosen Xcode.
- The destination names the simulator by its id, so the exact device is used. A simulator that is already
  booted is preferred; otherwise `xcodebuild` boots it. SnapshotKit never creates or deletes simulators.
- `-collect-test-diagnostics never` is added (unless you configure it) because collecting diagnostics after a
  failure can take ten minutes.
- With no scheme configured, SnapshotKit asks `xcodebuild -list` and uses the only scheme, or the
  `<Package>-Package` scheme of a Swift package.

Each repository keeps its own result bundles in `.git/snapshotkit/results/` (inside its git directory, so
never committed), with their exported failure images next to them: the newest 10 runs, and always the last
run’s, whatever other projects run.

## Running part of the tests

- **Test target** (Run › Scope): run only one test target. The list is built from the targets that have
  `__Snapshots__` folders. The choice is stored per project.
- `onlyTesting` / `skipTesting` in `.snapshotkit.yml`: a fixed selection for everyone.
- From the command line: `snapkit run --only AppSnapshotTests/CheckoutViewTests` (repeatable) or
  `--module AppSnapshotTests`.

## More run actions

Next to **Run Tests**, Run has a **Re-record Failing Suites** button and a **···** menu. The same actions are in
the **Snapshots** menu, some under other names:

| In Run | In the Snapshots menu | Shortcut | Does |
|---|---|---|---|
| **Re-record Failing Suites** | Re-record Failing Suites | ⌥⇧⌘R | re-records the failing suites of the last run, then verifies. [Re-recording](re-recording.md) |
| ··· › **Re-record All Snapshot Tests…** | Re-record All Snapshot Tests… | | re-records every snapshot test, after asking. |
| ··· › **Check Flakiness of Failing Tests** | Check Flakiness of Failing Tests | ⌥⌘R | runs the failing tests repeatedly (Settings › Flakiness check runs, 5 by default). [Flakiness](failures.md#checking-for-flakiness) |
| ··· › On *host* › **Run Tests** | Run on Remote Machine | ⌃⌘R | the same run on another Mac over SSH. [Remote runs](remote-runs.md) |
| ··· › On *host* › **Re-record Failing Suites** / **Check Flakiness of Failing Tests** | | | the same, remotely. |

## After a run

| Where | What you see |
|---|---|
| Run › Results | every test with its outcome |
| Last Run | the failing snapshots, with reference, actual and difference. [Failures](failures.md) |
| Library | failing snapshots marked with ✕ |
| Sidebar, Dock, menu bar | the failing count |

The last run is remembered per clone (`.git/snapshotkit/last-run.json`), so Last Run still shows it after a
restart, and `snapkit rerecord` / `snapkit failures` in a terminal use it too. A run made with `snapkit` shows
in the app when you come back to it.
