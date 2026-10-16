# Changelog

## 0.1.0

First public release.

### Run and re-record
- Runs a project's snapshot tests with the configuration its CI uses, read from `.gitlab-ci.yml`,
  `.github/workflows` and the scripts they call, overridable in `.snapshotkit.yml`. Clear errors when the
  required Xcode or simulator is missing.
- Streams output with live pass/fail counts; cancel at any time. After a run, a results list by suite.
- Re-records only the failing suites by temporarily patching their record trait (Swift Testing and XCTest),
  then verifies. The patch is always undone: on error, cancel, Ctrl-C, SIGTERM, quit, or at the next launch
  after a crash. Edits made during the run are kept.
- Runs on a remote Mac over SSH (or a local directory) to reproduce CI-only failures, including re-recording
  references there.

### Investigate
- Compare views: side by side, slider, difference and toggle, with pinch zoom, pan, zoom to the changed
  pixels and a pixel inspector.
- Diagnoses every difference (invisible, a few pixels, size changed, visible) using the CIE94 colour
  difference behind `perceptualPrecision`, and suggests the precision that would pass.
- Flakiness checks that rerun failing tests N times, a strip of each test's recent runs, and run history that
  flags tests which both passed and failed on the same commit.
- Imports `.xcresult` bundles from CI.

### Review
- Lists every snapshot PNG that differs from the base branch (committed, uncommitted, new, deleted), grouped
  by suite, against the merge-base or the branch tip.
- *Viewed* marks like a code review, and a one-step discard for re-records that only picked up rendering
  noise.

### Projects and tools
- Scan folders, pins, recents, per-project base branch and a ⌘K switcher.
- The `snapkit` CLI covers the same features (`config`, `run`, `rerecord`, `flaky`, `failures`, `changes`,
  `history`, `diff`, `restore`, `projects`).
- A small Liquid Glass design system (docs/DESIGN.md), with fallbacks for macOS 14–25.
