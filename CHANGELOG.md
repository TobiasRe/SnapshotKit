# Changelog

All notable changes to SnapshotKit are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and SnapshotKit adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `snapkit failures` shows the images of every device and test case a test failed on, each labeled with its
  device and arguments, and lists every reference its failures name.
- Clearer errors: a shallow clone that lacks the merge-base says how to fetch it (`git fetch --unshallow`), a
  repository without commits that there is nothing to compare with, a missing `git` which PATH was searched,
  and `snapkit --repo` a folder that doesn’t exist.

### Changed
- Calmer lists: a snapshot’s row and grid tile say how it changed on one line (“● Uncommitted · dark”), with
  only failing tests marked on the right, and the detail’s chip uses the same word. The toolbar’s re-record
  button (the same as each detail header’s) is gone, and the Run tab lists Xcode and the simulator once.
- One main window: no New Window or window tabs; the Dock icon or the menu bar item brings it back.
- The same names everywhere: **Re-record Failing Suites** (Failures, Run tab, menus, ⌘K), **Check Flakiness of
  Failing Tests**, and **Zoom to Fit** for ⌘0. **Re-record All…** only ever means every snapshot.
- Flakiness reads “2 of 5 runs passed” and the history “4 of 8 recent runs passed”; failed and passed are
  circles everywhere, and status colors sit on icons rather than whole sentences.
- A test with more than three variants picks them from a menu instead of a wide segmented control.
- Each repository keeps its own result bundles and failure images in `.git/snapshotkit/results/` (the newest
  10 runs, always including the last); a run in one project no longer removes another’s.
- The Changes tab and `snapkit changes` list only snapshots, PNGs under `__Snapshots__` like the library;
  an app icon or test fixture no longer shows up as a change. Variants are ordered like the library’s.
- Messages use typographic quotes and apostrophes (“develop”, can’t); commands to type keep straight ones.
- `snapkit run` and `flaky` refuse `--iterations 1` (exit 64) instead of quietly running two.
- **Check Again** reloads the configuration, so a fixed `.snapshotkit.yml` is picked up.
- Faster with thousands of snapshots: the library loads in less than half the time, and a re-record starts
  seconds sooner.

### Fixed
- The sidebar stayed blank, and ⌘K showed only its backdrop, whenever no project was open at launch
  (including the first launch).
- Failures match their reference images when the repository was moved or copied, or the bundle came from CI.
- A test that ran on several simulators, or a parameterized test, counts a run per device and keeps every
  device’s and case’s images; a flakiness check on two simulators no longer calls a flaky test “Fails every
  time”. Run progress names a parameterized test once, by its name.
- Reverting a snapshot renamed only in case no longer deletes it.
- Recording works in test files with Windows line endings, a byte order mark, or a `@Suite(...)` ending in a
  comment or a comma.
- Tests named with raw identifiers (`` `pay button`() ``) no longer show as orphaned, and a change names its
  test like the library does (`payButton`, not `payButton.dark`).
- CI files: block-list matrices, `KEY=value xcodebuild …`, folded (`>`) commands, unquoted `${{ … }}`, several
  `xcodebuild` calls on one line and commented-out lines are read correctly.
- A `.snapshotkit.yml` that starts with `---` can be read.
- Without an OS, or with `latest`, runs use the newest simulator runtime, as CI does, not an older booted one.
- A run that records a new reference no longer makes the test look flaky.
- The diagnosis never suggests `perceptualPrecision: 1` or `precision: 0`, which can’t pass or pass anything;
  a few visible pixels over rendering noise get both `precision` and `perceptualPrecision`.
- Remote runs sync submodules, and download recorded snapshots with spaces or non-ASCII names.
- The ⌘K palette no longer lists projects whose path merely contains the typed letters somewhere.
- A project opened through a symbolic link shares its settings and history with the real path, as `snapkit`
  does.
- VoiceOver reads the names of icon menus (··· and the re-record arrow) instead of “More” or “Down”.
- Re-recording one test no longer clears the other failures of the last run; only the tests that ran are
  updated, in the app, in `snapkit` and in `.git/snapshotkit/last-run.json`. A test that still fails after
  re-recording shows its images.
- A canceled run, re-record, verification or flakiness check keeps the last run’s failures and verdicts
  instead of wiping them, and says “Cancelled.” rather than reporting a result. In `snapkit`, a Ctrl-C after
  recording says “Recorded; the verification was cancelled.” and exits 1.
- A re-record whose build failed, or that ran no test, says “Nothing was recorded” (and `snapkit record` /
  `rerecord` exit 1) instead of “Recorded”; a verification that ran no test says it couldn’t verify.
- Counts read right with one (“1 test passed”, “1 fails every time”), a run in which no test ran says so, and
  `snapkit` prints “▸ Finished” once.
- The Dock badge counts failing tests, not a flakiness check’s failed repetitions.
- Moving snapshots to the Trash says which couldn’t be moved, and why.
- Deleting, discarding or reverting the selected item selects the next one instead of jumping to the top, and
  lists start at their first visible row. A filter that hides the selection moves it to the first row shown.
- Overlapping refreshes of the library, Changes or the Xcode check no longer show an older result over a newer
  one; a reload no longer replaces imported failures with the last local run’s.
- A branch checked out outside the app shows up when you come back to it; a repository folder deleted or moved
  while open is reported as gone.
- A flakiness check, remote re-record or import that finishes no longer pulls you away from the tab you moved
  to meanwhile.
- When the image size changed, each side is drawn at its own size; sizes and coordinates no longer read as
  decimals in locales like German. Zooming keeps the pixel under the pointer in place.
- Opening a folder that doesn’t exist or isn’t a git repository says so instead of adding it as a project.
- Opening the base version of two snapshots of the same test, or of a branch like `release/1.0`, opens the
  right image.
- The same notice (“All 12 tests passed.”) shows again after it was closed.

## [0.2.0] - 2026-10-20

### Added
- Hosted documentation at [tobiasre.github.io/SnapshotKit/docs](https://tobiasre.github.io/SnapshotKit/docs/),
  linked from the website and the README.
- Revert any change to the base branch from the Changes tab (committed, uncommitted, new or deleted), one at a
  time or everything the list shows.
- Select several failures (⌘-click or ⇧-click) to re-record or flakiness-check just those.
- `snapkit rerecord --remote` verifies on the remote Mac, like a local re-record (skip with `--no-verify`).

### Changed
- "Re-record Failing Tests" is now **Re-record Failing Suites**, which is what it always did.
- `snapkit` rejects options a command doesn't take, and missing or malformed values (exit status 64).
- `snapkit flaky` exits 1 when a test is flaky or fails every time; `snapkit diff` exits 2 when an image can't
  be read. Color honors `NO_COLOR`; notes and warnings go to standard error.

### Fixed
- Clicking a row in the library, Changes and Failures lists selects it again; only the keyboard did before.
- Selecting a row no longer logs SwiftUI runtime warnings ("Publishing changes from within view updates").
- A snapshot brought back after the branch deleted it no longer shows as new when it matches the base branch.
- `snapkit failures --out DIR` no longer deletes the other files in DIR.
- Run history, settings and the record-patch registry are kept (as a `.corrupt` copy) when they can't be read,
  instead of being overwritten; the app and `snapkit` no longer overwrite each other's settings.
- Snapshots with non-ASCII file names appear in the library, the Changes tab and remote syncs.
- Failures match their reference image when the project sets a diff tool such as `snapkit open`.
- Viewed marks are kept in linked worktrees.
- The first Ctrl-C in `snapkit` cancels the run and still prints its summary; the second quits.
- A record patch that can't be undone at launch is reported instead of silently skipped.
- `remoteHost` values that look like `ssh` options are refused.
- Long `git` and `xcodebuild` calls no longer hold up the rest of the app while they run.

## [0.1.1] - 2026-10-17

### Added
- Use SnapshotKit as swift-snapshot-testing's diff tool: with `snapkit open` as the diff tool, a failure
  message ends in a command that opens the reference and the actual image in a SnapshotKit compare window,
  with Show in Project. Other tools can open it with a `snapshotkit://compare` link.
  See [Using SnapshotKit as your diff tool](https://tobiasre.github.io/SnapshotKit/docs/diff-tool/).

## [0.1.0] - 2026-10-17

First public release: a macOS app and CLI for inspecting, managing and updating the reference images of
snapshot tests built with swift-snapshot-testing.

### Browse and inspect
- A library of every snapshot in a project, by module, test file and test, as a list with a large preview or
  as a grid. Filter by name; narrow to changed, failing, uncommitted or orphaned snapshots; sort by name, size
  or recency.
- A snapshot's variants (light/dark, devices, named states) to switch between or compare side by side, and
  its committed versions with author, date and message to compare against.
- Zoom, pan, a pixel inspector and zoom to the changed pixels in every image view.

### Review
- Every snapshot PNG that differs from the base branch (committed, uncommitted, new, deleted), against the
  merge-base or the branch tip, with side-by-side, slider, difference and toggle views.
- *Viewed* marks like a code review (one at a time with V, or all at once), and one-step discard of re-records
  that only picked up rendering noise. Each change names the commit that last touched it.

### Update
- Re-record any test, suite or filtered set of snapshots, all failing tests, or every snapshot test (from
  the Run button's menu in the toolbar). The record trait is patched
  temporarily (Swift Testing and XCTest) and always restored: on error, cancel, Ctrl-C, SIGTERM, quit, or at
  the next launch after a crash, keeping edits made during the run. The new references are verified.
- Re-record on a remote Mac over SSH to get references rendered on the CI machine.

### Manage and share
- Orphaned snapshots (their test no longer exists) are found and can be moved to the Trash.
- Copy a snapshot (⌘C), or a side-by-side image of before, after and the difference; drag snapshots out;
  Quick Look with Space.

### Failing and flaky tests
- Reference vs. actual vs. difference for the last run or an `.xcresult` from CI.
- Each difference is diagnosed (invisible, a few pixels, size changed, visible) using the CIE94 color
  difference behind `perceptualPrecision`, with the precision that would pass.
- Flakiness checks, a strip of each test's recent runs, and run history that flags tests which both passed
  and failed on the same commit.

### Run
- Runs snapshot tests with the configuration CI uses, read from `.gitlab-ci.yml`, `.github/workflows` and the
  scripts they call, overridable in `.snapshotkit.yml`, with clear errors for a missing Xcode or simulator.
- Streams output with live counts; a results list by suite afterwards. Runs on a remote Mac over SSH too.

### Projects and tools
- Snapshots written outside the app (a re-record from Xcode or the CLI) appear while the window is open.
- Scan folders that find repositories with snapshot tests up to six levels deep (recorded or not yet, committed
  or not) and say what they found; pins, recents, per-project base branch, and a ⌘K palette for projects and
  commands. ⌘F filters the current list; ⌥⌘O opens a snapshot's test in Xcode at its function.
- An optional menu bar item with run progress (a pie and a done/total count), the failing count, Cancel,
  and one-click access to failing, pinned and recent projects.
- The `snapkit` CLI covers the same ground: `snapshots`, `record`, `changes`, `run`, `rerecord`, `flaky`,
  `failures`, `history`, `diff`, `restore`, `config`, `projects`.
- A consistent Liquid Glass look, with fallbacks for macOS 14–25.
- `scripts/make-samples.sh` generates five sample projects with real recorded snapshots, feature branches,
  changes and failures, to try SnapshotKit on.

[Unreleased]: https://github.com/TobiasRe/SnapshotKit/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/TobiasRe/SnapshotKit/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/TobiasRe/SnapshotKit/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/TobiasRe/SnapshotKit/releases/tag/v0.1.0
