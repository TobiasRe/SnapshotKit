# Changelog

All notable changes to SnapshotKit are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and SnapshotKit adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
