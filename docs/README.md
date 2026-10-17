# SnapshotKit documentation

**SnapshotKit is a companion for projects that test with
[swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing).** Your tests keep recording
reference images exactly as they do today; SnapshotKit — a native Mac app, menu bar item and command-line tool —
works with those images: browse every snapshot, review what your branch changed, run the tests the way CI does,
find out why they failed, and re-record what should change.

![SnapshotKit comparing a changed snapshot side by side: the same screen on the base branch and on the feature branch](images/compare.png)

> **What SnapshotKit is not.** It isn't a snapshot testing library and doesn't replace swift-snapshot-testing.
> There's no package to add and no test code to change: it reads your repository (the `__Snapshots__` folders,
> your test sources and CI files) and the results your test runs produce. Without swift-snapshot-testing in your
> project there's nothing for it to show — start with
> [Point-Free's library](https://github.com/pointfreeco/swift-snapshot-testing), then come back.

## How it fits in

1. **You test with swift-snapshot-testing** — `assertSnapshot(of: view, as: .image)` in Swift Testing or XCTest.
2. **The tests record reference images** — PNGs in `__Snapshots__` folders next to the test files, committed to
   your repository.
3. **SnapshotKit works with them** — it finds the images, reads how CI runs the tests, shows changes and
   failures, and re-records by switching swift-snapshot-testing's record mode on and off for you.

## Start here

- **[Getting started](getting-started.md)** — install, add your first project, try the sample projects, where
  SnapshotKit keeps things.

## Using the app

| Page | Covers |
|---|---|
| [Projects and scanning](projects.md) | adding projects, scan folders, the sidebar, the ⌘K palette, the window, notices, settings |
| [The snapshot library](library.md) | the Snapshots tab: naming, filtering, scopes, sorting, the detail, variants and history, orphans |
| [Reviewing changes](changes.md) | the Changes tab: kinds of change, the base branch, merge-base vs tip, Viewed marks, discarding noise |
| [Failures and flaky tests](failures.md) | the Failures tab: result bundles, diagnosis, history strips, flakiness checks, run history |
| [Comparing images](comparing.md) | the compare view: modes, zoom, pixel readout, the diagnosis and suggested precision |
| [Running tests](running.md) | the Run tab: how runs mirror CI, the command, scope, results |
| [Re-recording](re-recording.md) | what can be re-recorded, the record patch, how it is always restored, verification |
| [Remote runs](remote-runs.md) | running, recording and checking flakiness on another Mac over SSH |
| [The menu bar item](menu-bar.md) | run progress, failing counts and quick access from the menu bar |
| [Keyboard shortcuts](keyboard-shortcuts.md) | every shortcut |

## Reference

| Page | Covers |
|---|---|
| [Configuration](configuration.md) | what is read from CI, `.snapshotkit.yml` keys, precedence, base branch, Xcode and simulator selection, files and environment variables |
| [The `snapkit` CLI](cli.md) | every command, option, output and exit status |
| [Using SnapshotKit as your diff tool](diff-tool.md) | `snapkit open` with swift-snapshot-testing's `diffTool`, and `snapshotkit://` links |
| [Troubleshooting and FAQ](troubleshooting.md) | error messages and what to do about them |

## For contributors

| Page | Covers |
|---|---|
| [Design](design.md) | the app's design system: principles, tokens, components |
| [The README's Development section](https://github.com/TobiasRe/SnapshotKit#development) | building, testing, the end-to-end script, sample projects |

## Concepts in one minute

- **Reference image (snapshot)** — the PNG a snapshot test compares against, stored in a `__Snapshots__` folder
  next to the test file.
- **Variant** — one test can record several images: `payButton.light.png`, `payButton.dark.png`.
- **Re-recording** — replacing references with what the tests render now. SnapshotKit switches record mode on in
  the test source just for the run and always switches it off again.
- **Base branch** — the branch your changes are compared with (`develop`, `main`), as in a pull request.
- **Run like CI** — SnapshotKit reads your CI files and runs `xcodebuild` with the same scheme, test plan,
  selection, simulator and Xcode version, so local results match CI.
- **Invisible difference** — pixels that differ by less than anyone can see (ΔE below 2.3), typical of rendering
  on a different machine. SnapshotKit names it and suggests the `perceptualPrecision` that would pass.
- **Flaky test** — a test that passes and fails without a code change. SnapshotKit finds them by running tests
  repeatedly and by remembering every run.
