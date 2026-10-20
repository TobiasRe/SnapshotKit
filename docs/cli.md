# The `snapkit` command-line tool

`snapkit` does what the app does, in a terminal or a script: list and filter snapshots, compare with the base
branch, run tests the way CI does, re-record, check flakiness, read CI result bundles and compare two images.
It reads the same configuration and history as the app, so you can switch between them freely.

```
snapkit <command> [options]
```

Install it from the release (`snapkit-<version>-macos-arm64.zip`) or build it with `scripts/make-app.sh`. See
[Getting started](getting-started.md#install-the-command-line-tool).

## Commands at a glance

| Command | Does |
|---|---|
| [`snapshots`](#snapshots) | list every snapshot with its state |
| [`changes`](#changes) | snapshots that differ from the base branch |
| [`config`](#config) | the resolved configuration, and an Xcode/simulator check |
| [`run`](#run) | run the snapshot tests like CI, locally or remotely |
| [`record`](#record) | re-record the tests of matching snapshots, then verify |
| [`rerecord`](#rerecord) | re-record the failing suites of the last run, then verify |
| [`flaky`](#flaky) | run the failing tests repeatedly and classify them |
| [`failures`](#failures) | list and diagnose failures of the last run or an `.xcresult` |
| [`history`](#history) | recent runs and flaky tests |
| [`diff`](#diff) | compare two PNGs and diagnose the difference |
| [`open`](#open) | compare two PNGs in the app (the diff tool for swift-snapshot-testing) |
| [`restore`](#restore) | undo a leftover record patch |
| [`projects`](#projects) | scan folders for projects, or list them |
| `help`, `version` | usage, and `snapkit <version>` |

## Common behavior

**Which repository.** `--repo PATH`, or the current directory. Any folder inside a repository works: `snapkit`
uses the repository’s root (`git rev-parse --show-toplevel`). Outside a repository: *error: … is not inside a
git repository*; a `--repo` folder that doesn’t exist: *error: no such folder: …*. Without `git`: *error: `git`
was not found on the PATH (…). Install Xcode or its command line tools (`xcode-select --install`).*

**Configuration.** Commands that run tests read the CI files, `.snapshotkit.yml` and the per-project settings
the app stores, in that order. See [Configuration](configuration.md). `snapshots`, `diff`, `open`, `restore`
and `projects` don’t need it.

**Options** come after the command, in any order. Repeating an option keeps the last value, except `--only`
and `--suite`, which collect every value. An option the command doesn’t take, a missing or malformed value, or
an extra argument is an error (exit status 64).

**Output.** Color only when writing to a terminal, and never with `NO_COLOR` set. Errors go to standard error
as `error: …`, and so do notes and warnings (a restored record patch, *Interrupted…*). Progress lines
start with `▸`, SnapshotKit’s own notes with `snapkit:`. Test output is shortened to what matters (suites,
failures, errors, the summary); `--verbose` prints everything `xcodebuild` prints.

**Exit status.**

| Status | Meaning |
|---|---|
| 0 | done (for `run`, `record`, `rerecord`: tests passed or verified) |
| 1 | an error, failing tests or a failed verification (see each command) |
| 2 | Xcode or the simulator isn’t available as configured; for `diff`, an image that can’t be read or written |
| 64 | wrong options or arguments |
| 130, 143… | interrupted by a signal (128 + the signal number) |

**Leftover record patches.** Every command first restores record patches left behind by a run that was killed
or crashed — in any registered project, not only this one — and says so: *snapkit: restored leftover record
patch in … :*. See [Re-recording](re-recording.md#always-restored).

Example outputs on this page are shortened; the `record`, `rerecord` and `flaky` ones are illustrative.

**Interrupting.** Ctrl-C cancels the running `xcodebuild` and restores any record patch before `snapkit` exits;
it prints *Interrupted — cancelling (press Ctrl-C again to force quit)…*. SIGTERM, SIGHUP and SIGQUIT restore too.

## snapshots

```
snapkit snapshots [--repo PATH] [--filter TEXT] [--orphans] [--sort size|recent]
```

Lists every snapshot image (`**/__Snapshots__/**/*.png`, committed or not, unless ignored), one per line with
its size and state (`modified`, `new`, `orphaned`), then a summary.

| Option | |
|---|---|
| `--filter TEXT` | only paths containing every word of TEXT (case-insensitive) |
| `--orphans` | only snapshots whose test no longer exists |
| `--sort size` | largest first |
| `--sort recent` | most recently modified first |

```
$ snapkit snapshots --sort size --filter today
Tests/WeatherTests/__Snapshots__/WeatherScreenTests/today.iPhone13ProMax.png  226 KB  modified
Tests/WeatherTests/__Snapshots__/WeatherScreenTests/today.iPhoneSE.png  146 KB  modified
2 of 28 snapshots · 1 test · 372 KB
```

Read-only; exits 0.

## changes

```
snapkit changes [--repo PATH] [--base BRANCH] [--tip] [--filter TEXT]
```

The snapshots (PNGs under `__Snapshots__`, as `snapshots` lists them) that differ between the base branch and
your working tree, grouped by folder, each with its kind: **Committed** (on this branch), **Uncommitted**,
**New** or **Deleted**.

| Option | |
|---|---|
| `--base BRANCH` | compare with this branch instead of the configured or detected one |
| `--tip` | compare with the base branch’s tip instead of the merge-base |
| `--filter TEXT` | only paths containing every word |

```
$ snapkit changes
Snapshots changed vs develop (Merge-base 0ad108e8): 22
BubbleTests
  Uncommitted  Tests/ChatTests/__Snapshots__/BubbleTests/emoji.dark.png
  …
ReactionTests
  New          Tests/ChatTests/__Snapshots__/ReactionTests/reacted.dark.png
```

`origin/<branch>` is preferred over a local branch. Read-only; exits 0, or 1 when there is nothing to compare
with:

- *Base branch “x” was not found locally or on origin. Fetch it or choose a different base branch.*
- *This shallow clone doesn’t have the commit where the branch left origin/develop. Fetch the history (`git
  fetch --unshallow`), or compare with the branch tip.* `--tip` works without that history.
- *This branch has no history in common with origin/develop. Compare with the branch tip, or choose a different
  base branch.*
- *This repository has no commits yet, so there is nothing to compare with.*
- *No base branch; pass --base BRANCH*, when none is configured or detected.

## config

```
snapkit config [--repo PATH]
```

Prints the repository, the CI files read, whether a `.snapshotkit.yml` exists, every resolved value with its
source, the test targets with snapshots, notes about anything guessed or ignored, and checks Xcode and the
simulator:

```
  scheme         Shop  (.github/workflows/snapshots.yml)
  …
snapkit: Xcode 16.2 · iPhone 16 Pro iOS 18.2
```

Exits 2 when Xcode or the simulator is missing, 1 when the configuration can’t be read. See
[Configuration](configuration.md).

## run

```
snapkit run [--repo PATH] [--only ID]… [--module TARGET] [--iterations N] [--remote [HOST]] [--verbose]
```

Runs the snapshot tests with the CI configuration (see [Running tests](running.md)).

| Option | |
|---|---|
| `--only ID` | run only this test identifier (`Bundle`, `Bundle/Suite` or `Bundle/Suite/test()`); repeatable; replaces CI’s selection |
| `--module TARGET` | run only this test target |
| `--iterations N` | run every test N times, each in a fresh process; a flakiness check. N must be at least 2 (else exit 64) |
| `--remote` | run on the configured remote host |
| `--remote HOST` | run on HOST, this once (`local` uses a local directory) |
| `--verbose` | print all `xcodebuild` output |

At the end:

```
Result: 12 passed, 2 failed, 0 skipped  [local]
FAILING SUITE: AppSnapshotTests/CheckoutViewTests (1/2 tests)
  ✘ payButton()
Result bundle: …/Shop/.git/snapshotkit/results/2026-10-16T17-47-50Z-8C7AFB53.xcresult
Failure images: 2 (see `snapkit failures`)
```

plus up to ten build errors when the build failed. A canceled run starts the summary with *Cancelled.* The run
is added to the history and, without `--iterations`, remembered as the last run, which the app’s Failures tab
and `rerecord` / `failures` use. A canceled run isn’t: the last run’s failures stay as they were.

Exits 0 when the tests passed, 1 when they failed, the build failed or the run was canceled.

## record

```
snapkit record [--repo PATH] TEXT… [--whole-suite] [--no-verify] [--verbose]
```

Re-records the tests of every snapshot whose path contains all the words of TEXT (orphans excluded), then
verifies them. TEXT can name a test, a suite, a variant or any part of the path.

| Option | |
|---|---|
| `--whole-suite` | run the whole suites of the matching snapshots, not just their tests |
| `--no-verify` | skip the verification run |
| `--verbose` | print all `xcodebuild` output |

```
$ snapkit record CheckoutViewTests dark
snapkit: recording AppSnapshotTests/CheckoutViewTests/payButton()
snapkit: Xcode 16.2 · iPhone 16 Pro iOS 18.2
▸ Finding suite sources
▸ Enabling record mode
snapkit: record mode enabled in Tests/AppSnapshotTests/CheckoutViewTests.swift (CheckoutViewTests)
▸ Recording snapshots
▸ Restoring test sources
▸ Verifying new references
Recorded and verified: 2 passed.
```

Other endings: *Recorded, but verification failed: 1 still failing (flaky?).* and, with `--no-verify`,
*Recorded.* If the test source couldn’t be restored automatically you get a `WARNING:` naming the backup.
Canceled while recording: *Cancelled.* Canceled during the verification, or before it started: *Recorded; the
verification was cancelled.*

The verification’s results go into the last run: the tests it ran replace their earlier results, every other
test keeps its own (see [`rerecord`](#rerecord)).

No match: *No snapshot path contains “x” and “y”.* When the build fails or no test runs, nothing is recorded:
*Nothing was recorded: the build failed (…).* or *Nothing was recorded: no test ran.* Exits 0 when verified (or
recorded, with `--no-verify`), 1 when nothing was recorded, verification fails or something was canceled. See
[Re-recording](re-recording.md).

## rerecord

```
snapkit rerecord [--repo PATH] [--suite ID]… [--no-verify] [--remote [HOST]] [--verbose]
```

Re-records **whole failing suites**, then verifies them.

- Without `--suite`: the failing suites of the last run (*snapkit: using failing suites from the last run
  (local, 10:42)*). If there’s no last run, it runs the tests first to find them.
- `--suite ID` (repeatable): these suites (`Bundle/Suite`); a bare suite name works when the last run had it.
- `--remote [HOST]`: record on the remote Mac; your files aren’t patched, the new PNGs are downloaded, then
  verified on the remote Mac (unless `--no-verify`). See [Remote runs](remote-runs.md).

```
Recorded suites: AppSnapshotTests/CheckoutViewTests
Patched and restored: Tests/AppSnapshotTests/CheckoutViewTests.swift
Verified: 3 passed with the new references.
```

Or *Verification failed: 1 still failing (flaky?). Try `snapkit flaky`.* If the build fails or no test runs:
*Nothing was recorded: …* (exit 1). Canceled: *Cancelled.*, or *Recorded; the verification was cancelled.* once
the recording is done (exit 1). Nothing failing: *Nothing to re-record: no failing suites.* (exit 0).

The verification is merged into the last run rather than replacing it: the suites it ran get their new
results, and the last run’s other failures stay, so you can re-record one suite at a time. The last run’s
result bundle switches to the verification’s only once every suite that still fails was part of it. A
canceled verification changes nothing.

## flaky

```
snapkit flaky [--repo PATH] [--iterations N] [--suite ID]… [--remote [HOST]] [--verbose]
```

Runs the failing suites (as `rerecord` picks them) N times — `--iterations` (at least 2), else the app’s
setting, default 5 — each repetition in a fresh process, and prints a verdict per test:

```
snapkit: running AppSnapshotTests/CheckoutViewTests 5×
Fails every time   0✔ 5✘  CheckoutViewTests/payButton()
Flaky              3✔ 2✘  CheckoutViewTests/summary()
```

Verdicts: **Fails every time**, **Flaky**, **Passes**. Recorded in the history. Exits 0 when every test passes,
1 when one is flaky or fails every time (or no result could be read).

## failures

```
snapkit failures [--repo PATH] [--xcresult PATH] [--out DIR]
```

Lists the failing tests of the last run, or of an `.xcresult` (for example a CI artifact), with their images and
a diagnosis:

```
ShopTests/ProductCardTests
  ✘ trailShoes()  (1/1 repetitions failed)
    reference: Tests/ShopTests/__Snapshots__/ProductCardTests/trailShoes.light.png
    failure:    /…/trailShoes.attachments/…png
    difference: /…/…png
    Visible change in a 105×58 area at 847, 136.
    recent runs: ✔ ✔ ✘
```

Every reference the test’s failure messages name is listed once. When the test ran on several simulators, or
is parameterized and several of its cases failed, each set of images is labeled with its device, its
arguments, or both:

```
ShopTests/BadgeTests
  ✘ badge(style:)  (2/2 repetitions failed)
    reference: Tests/ShopTests/__Snapshots__/BadgeTests/badge-style.dark.png
    reference: Tests/ShopTests/__Snapshots__/BadgeTests/badge-style.light.png
    iPhone 16 Pro · "dark":
    failure:    /…/…png
    difference: /…/…png
    Visible change in a 40×12 area at 8, 4.
    iPhone SE (3rd generation) · "light":
    failure:    /…/…png
    difference: /…/…png
    No visible difference (largest ΔE 0.8), typical of rendering on another machine or OS version. Would pass with perceptualPrecision: 0.99.
```

Images are shown for the first repetition. For an invisible or tiny difference the diagnosis ends with *Would
pass with …*: `perceptualPrecision: …`, `precision: …`, or both (see
[Comparing images](comparing.md#the-diagnosis)).

| Option | |
|---|---|
| `--xcresult PATH` | read this result bundle instead of the last run’s |
| `--out DIR` | where to export the failure images (default: next to the bundle, `<bundle>.attachments`). Only the files of an earlier export there are replaced. |

An imported bundle is added to the history (once). No failures: *No failing tests in ….* Without a local bundle:
*No local result bundle. Pass --xcresult PATH (e.g. a CI artifact).* If the last run’s bundle has been removed:
*The last run’s results are gone (…). Run the tests again (`snapkit run`), or pass --xcresult PATH.* Exits 0
after listing, failures or not; 1 when there is no bundle or it can’t be read.

## history

```
snapkit history [--repo PATH] [TEST]
```

Without TEST: the last 15 runs (date, kind, host, passed/failed, commit, `+dirty` when the tree had changes), then
the tests flagged as flaky because they passed and failed on the same commit:

```
$ snapkit history
10/16/2026, 7:48 PM  run        local        10✔ 3✘  00ec4128+dirty
No flaky signals.
```

When there are flaky signals, the second part reads *Flaky (passed and failed on the same commit):* followed by
each test, its passes and failures, the hosts it failed on and its strip. Dates follow your system’s format.

With TEST (`Bundle/Suite/test()`): the same runs and flaky signals, then that test’s strip (up to 30 runs,
oldest first) and one line per run. Kinds:
`run`, `record`, `verify`, `flakeCheck`, `imported`. Exits 0.

## diff

```
snapkit diff A.png B.png [-o OUT.png]
```

Compares two PNGs (no repository needed) and explains the difference:

```
$ snapkit diff reference.png failure.png
1468 pixels differ (0.436%), largest ΔE 85.3
Visible change in a 105×58 area at 847, 136.
```

For invisible or tiny differences it adds *Would pass with: perceptualPrecision: 0.99* (or `precision: …`, or
both).
`-o OUT.png` writes the difference image (changed pixels in magenta). Exits 0 when the images are identical, 1
when they differ, 2 when one can’t be read or `-o` can’t be written. See [Comparing images](comparing.md#the-diagnosis).

## open

```
snapkit open REFERENCE.png ACTUAL.png [--app PATH]
```

Prints the same summary as `diff`, then opens the pair in a SnapshotKit compare window. This is the command to
name as swift-snapshot-testing’s diff tool — see [Using SnapshotKit as your diff tool](diff-tool.md).

| Option | |
|---|---|
| `--app PATH` | the app to open, e.g. a development build; also `SNAPSHOTKIT_APP` |

Without either, it opens the installed SnapshotKit.app by its bundle id. Missing files: *no such file: …*. No
app: *Couldn’t open SnapshotKit. Install SnapshotKit.app from https://github.com/TobiasRe/SnapshotKit/releases,
or pass --app PATH.* (exit 1). Otherwise exits 0, whether or not the images differ.

## restore

```
snapkit restore [--repo PATH] [--force]
```

Restores a record patch left in this repository’s test sources, the same way the automatic restore does, and
prints what it did, or *No record patch to restore.* If a SnapshotKit or `snapkit` process that is still running
owns the patch, it refuses (*A re-record is already in progress for …*); `--force` restores anyway.

## projects

```
snapkit projects scan FOLDER…
snapkit projects [list]
```

`scan` adds the folders as scan folders (in the app’s settings), rescans every scan folder and lists the
projects found: *5 project(s) with snapshot tests (looked 6 folders deep).* Folders macOS doesn’t allow it to
read are named. `list` prints the app’s projects: pinned (📌) first, then recent, then the rest. See
[Projects and scanning](projects.md).

## Environment variables

| Variable | |
|---|---|
| `SNAPSHOTKIT_HOME` | settings, history and patch registry folder (default `~/Library/Application Support/SnapshotKit`) |
| `SNAPSHOTKIT_APP` | the app `snapkit open` opens |
| `SNAPSHOTKIT_XCODE_SEARCH_PATHS` | colon-separated folders searched for `Xcode*.app` (default `/Applications` and `~/Applications`) |

## In CI and scripts

`snapkit` works without the app, so CI jobs and scripts can use it:

```bash
# Fail the job with a readable report when snapshots fail
snapkit run || { snapkit failures; exit 1; }

# Explain the snapshot failures of a downloaded CI artifact
snapkit failures --xcresult artifacts/Tests.xcresult --out artifacts/snapshot-failures

# List oversized references in a pull request check
snapkit snapshots --sort size | head -20
```
