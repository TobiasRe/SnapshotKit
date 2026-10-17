# Changelog

## 0.1.1 — 2026-10-17

- Use SnapshotKit as swift-snapshot-testing's diff tool: with `.snapshots(diffTool: "snapkit open")`, a
  failure message ends in a command that opens the reference and the actual image in a SnapshotKit compare
  window, with Show in Project. Other tools can open it with a `snapshotkit://compare` link.

## 0.1.0

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
- Each difference is diagnosed (invisible, a few pixels, size changed, visible) using the CIE94 colour
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
- A small Liquid Glass design system (docs/design.md), with fallbacks for macOS 14–25: one family of 28-point
  glass controls (icon circles, text capsules, segmented pills, fields and one accent action per region),
  header, filter and footer bars of fixed heights that line up across panes, a "12 / 40" stepper in every
  detail, and calm dot-and-hairline status labels.
- `scripts/make-samples.sh` generates five sample projects with real recorded snapshots, feature branches,
  changes and failures, to try SnapshotKit on.
