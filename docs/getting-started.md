# Getting started

This page takes you from download to your first reviewed snapshot change.

SnapshotKit is a companion to [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing): you
need an iOS (or macOS) project whose tests already use it. SnapshotKit adds nothing to that project; it works with
the reference images the tests record and the results they produce.

## Requirements

| What | Requirement |
|---|---|
| Mac | Apple silicon, macOS 14 or later. Liquid Glass controls on macOS 26 and later; earlier versions get the same layout with flat controls. |
| Xcode | Xcode 16 or later (SnapshotKit reads results with `xcresulttool get test-results`), and whatever your project's tests need. SnapshotKit runs `xcodebuild test` the way your CI does (Swift packages too, through their scheme) and uses the Xcode version CI pins, when that version is installed. |
| Projects | Git repositories with snapshot tests built on swift-snapshot-testing (Swift Testing or XCTest). |

Browsing, reviewing changes and comparing images need nothing but the repository. Running and re-recording
tests need Xcode and a simulator runtime, like running the tests yourself.

## Install the app

1. Download `SnapshotKit-<version>-macos-arm64.zip` from the
   [latest release](https://github.com/TobiasRe/SnapshotKit/releases/latest).
2. Unzip it and move `SnapshotKit.app` to `/Applications`.
3. Open it. The app is ad-hoc signed and not notarized, so macOS blocks the first launch. Choose
   **Open Anyway** in System Settings › Privacy & Security, or remove the quarantine flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/SnapshotKit.app
   ```

## Install the command-line tool

`snapkit-<version>-macos-arm64.zip` from the same release contains the `snapkit` binary. Put it somewhere on
your `PATH`:

```bash
unzip snapkit-0.2.0-macos-arm64.zip
sudo mkdir -p /usr/local/bin
sudo mv snapkit /usr/local/bin/
xattr -d com.apple.quarantine /usr/local/bin/snapkit 2>/dev/null || true
snapkit --version
```

The `xattr` line removes the quarantine flag a browser download adds; without it, macOS may block the binary.

The CLI is optional: the app does everything on its own. See [the CLI reference](cli.md).

## Build from source

With Xcode 26 or later:

```bash
git clone https://github.com/TobiasRe/SnapshotKit
cd SnapshotKit
scripts/make-app.sh        # builds dist/SnapshotKit.app and dist/snapkit, plus release zips
```

`swift run SnapshotKit` starts the app straight from the package while you work on it.

## Add your first project

When SnapshotKit starts without projects it shows a welcome screen. There are three ways in:

- **Add Project…** (⌘O): choose a git repository. Any folder inside the repository works; SnapshotKit uses
  the repository's root.
- **Add Scan Folder…**: choose a folder that *contains* repositories, such as `~/Developer`. SnapshotKit
  looks up to six folders deep and adds every repository with snapshot tests. See
  [Projects and scanning](projects.md).
- **Drop a folder onto the window**: a repository is added as a project, any other folder as a scan folder.

The project opens on its **Snapshots** tab, the library of every reference image.

## Try it on sample projects

No project at hand? `scripts/make-samples.sh` (in the source repository) generates five Swift packages,
Shop, Weather, Chat, Fitness and DesignKit, with about 140 recorded snapshots. Four of them have a feature
branch with committed and uncommitted changes, a failing last run, an orphaned and a new snapshot, so every
tab has something to show:

```bash
scripts/make-samples.sh ~/Developer/snapshotkit-samples
```

It records the references on a dedicated simulator ("SnapshotKit Samples") and takes a few minutes. Then add
the folder as a scan folder.

## A first tour

1. **Snapshots** — every reference image, grouped by test target and test file. Select one to see it large,
   switch between its variants (light and dark, devices) and compare it with an earlier commit.
   See [The snapshot library](library.md).
2. **Changes** — every snapshot your branch changed compared with the base branch, side by side or as a
   difference, with *Viewed* marks like a code review. See [Reviewing changes](changes.md).
3. **Run** — run the snapshot tests exactly the way CI does (the configuration is read from your CI files).
   See [Running tests](running.md).
4. **Failures** — after a run (or after importing a CI `.xcresult`), every failing snapshot with reference,
   actual image and difference, diagnosed. See [Failures and flaky tests](failures.md).
5. **Re-record** — the camera button in a detail header (⇧⌘R) records the selected test again and verifies
   it; the arrow next to the toolbar's Run button re-records the failing suites or every snapshot test. See
   [Re-recording](re-recording.md).

Press ⌘K at any time to jump to a project or run a command by name.

## Where SnapshotKit keeps things

| What | Where |
|---|---|
| App settings: scan folders, pins, recents, preferences, and per-project choices (base branch, remote host, test target) | `~/Library/Application Support/SnapshotKit/settings.json` (Settings › Show in Finder) |
| Run history (every run, for flakiness and the history strips) | `~/Library/Application Support/SnapshotKit/history/` |
| Per-clone state: the last run, Viewed marks, a record patch in progress | the repository's `.git/snapshotkit/` folder (`last-run.json`, `viewed.json`, `record-patch.json`), so it never shows up in `git status` |
| Run results and failure images | the repository's git directory (`.git/snapshotkit/results/`): the newest 10 runs, and always the last run's |
| Project configuration you choose to commit | `.snapshotkit.yml` at the repository root. See [Configuration](configuration.md). |

`SNAPSHOTKIT_HOME` points the app and the CLI at another settings folder, which is useful for scripts and
tests.
