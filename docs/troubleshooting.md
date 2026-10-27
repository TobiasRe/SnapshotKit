# Troubleshooting and FAQ

## Opening the app

**“SnapshotKit can’t be opened because Apple cannot check it for malicious software.”**
The release is ad-hoc signed and not notarized. Choose **Open Anyway** in System Settings › Privacy & Security,
or run `xattr -dr com.apple.quarantine /Applications/SnapshotKit.app` once.

**`snapkit` is “killed” or blocked when run.**
Remove the quarantine flag: `xattr -d com.apple.quarantine /usr/local/bin/snapkit`.

## Projects

**Scanning finds nothing.**
The notice after the scan says why. Check that:
- the repositories are at most six folders below the scan folder,
- they have `__Snapshots__` images, a `.snapshotkit.yml` or a dependency on swift-snapshot-testing,
- they aren’t inside a skipped folder (`build`, `vendor`, `Pods`, `node_modules`, `DerivedData`, `Library`…).

Or add the repository directly with ⌘O.

**“SnapshotKit can’t read ~/…”** — macOS denied access to the folder (Desktop, Documents, Downloads and
external volumes are protected). Allow SnapshotKit in System Settings › Privacy & Security › Files and Folders,
then **Rescan Folders**.

**“Can’t open ~/…: it isn’t in a git repository.”**
SnapshotKit only works on git repositories: choose a folder inside one, or make the folder a repository
(`git init`). `snapkit` says *error: … is not inside a git repository*, and *no such folder: …* for a
`--repo` that doesn’t exist.

**“`git` was not found on the PATH (…).”**
SnapshotKit and `snapkit` run `git` (and `xcrun`, `xcodebuild`) from the PATH. Install Xcode or its command
line tools (`xcode-select --install`); in a script or CI job, check that the PATH it prints contains
`/usr/bin`.

**A project shows no snapshots, but it has some.**
SnapshotKit lists files under `__Snapshots__` folders that git tracks or that are untracked but not ignored. If
your `.gitignore` ignores the snapshot folder, git doesn’t see the files and neither does SnapshotKit.

## Running tests

Every problem SnapshotKit finds before a run is shown on the left of Run, under Environment or
Configuration, with the fix; the header offers **Check Again**. `snapkit config` prints the same checks.

| Message | Fix |
|---|---|
| *Xcode 16.2 is not installed (required by …). Installed: …* | Install that Xcode (developer.apple.com/download, or `xcodes install 16.2`), or set `xcode:` in `.snapshotkit.yml` to one you have. |
| *Xcode at … does not exist.* | Fix `developerDir:` in `.snapshotkit.yml`, or the path in CI. |
| *No Xcode installation found.* | Install Xcode and run `xcode-select -s /Applications/Xcode.app`. |
| *The iOS 18.2 simulator runtime is not installed for Xcode 16.2.* | `xcodebuild -downloadPlatform iOS -buildVersion 18.2`, or Xcode › Settings › Components. |
| *No “iPhone 16 Pro” simulator on iOS 18.2. Available on that runtime: …* | Create it: `xcrun simctl create "iPhone 16 Pro" "iPhone 16 Pro" <runtime-id>`, or set `device:` to an available one. |
| *No simulator is configured: CI has no `-destination` with a device name.* | Set `device:` (and `os:`) in `.snapshotkit.yml`. |
| *No scheme found. CI files do not contain an `xcodebuild -scheme …` call* | Add `scheme:` to `.snapshotkit.yml`. |
| *`.snapshotkit.yml` could not be read (line N: …)* | Fix that line; the file is flat `key: value` YAML without nesting. See [Configuration](configuration.md#format). |

**The configuration SnapshotKit found is wrong.**
Run `snapkit config` to see every value and where it came from, then override what’s wrong in
`.snapshotkit.yml`. Values typed in Run (base branch, remote host) override everything for you alone.

**My CI uses `swift test`, not `xcodebuild`.**
SnapshotKit runs `xcodebuild`. Set `scheme:` (for a package, `<Package>-Package`) and `device:` in
`.snapshotkit.yml`.

**A run takes ten minutes after a failure.**
That’s `xcodebuild` collecting diagnostics. SnapshotKit passes `-collect-test-diagnostics never` unless your
configuration sets it otherwise; check `extraArguments`.

## Snapshots and failures

**Tests pass in SnapshotKit but fail in CI (or the other way round) with an *Invisible* difference.**
The references were rendered on a different machine, GPU or OS version. Record on the machine CI uses
([Remote runs](remote-runs.md)), or loosen `perceptualPrecision` to the value the diagnosis suggests. Don’t
re-record locally: that just moves the failure.

**After re-recording, verification still fails.**
The test isn’t deterministic. Run **Check Flakiness** and look for animations, async loading, the current date or
random data in the view.

**Re-recording says: “CheckoutTests” in … already overrides invokeTest(); re-record it manually.**
SnapshotKit adds an `invokeTest` override to XCTest classes to switch record mode on. If the class already has
one, wrap its body in `withSnapshotTesting(record: .all) { … }` yourself for the recording run.

**A snapshot is marked Orphaned, but its test exists.**
Orphans are found by looking for `func <testName>(` in `<suite folder>.swift`. Tests in a file with another name,
or whose snapshot names are built at run time, can look orphaned. Don’t trash those.

## The record patch

**My test file still contains `// snapshotkit:record`, or a `record: .all` in its `@Suite`.**
That shouldn’t survive a run. (SnapshotKit marks the lines it inserts with the comment, but edits an existing
`@Suite` in place, so a leftover there has no marker.) Restore it: open SnapshotKit or run `snapkit restore` in the repository. If the file
changed too much to restore automatically, the original is in `.git/snapshotkit/backups/`.

**“A re-record is already in progress for …”**
Another SnapshotKit or `snapkit` process is recording in this repository. Wait for it, cancel it, or — if you’re
sure it’s gone — `snapkit restore --force`.

## Changes

**Changes vs develop says: Base branch “develop” was not found locally or on origin.**
Fetch it (`git fetch origin develop`), or pick another base branch in the branch menu of vs develop.

**“This shallow clone doesn’t have the commit where the branch left origin/develop.”**
The clone has only the latest commits (CI often clones with `--depth`), so the merge-base isn’t there. Fetch
the history with `git fetch --unshallow`, or switch vs develop to **Branch tip** (`snapkit changes
--tip`). Without a shallow clone, the same problem reads *This branch has no history in common with …*: pick
another base branch, or compare with the tip.

**“This repository has no commits yet, so there is nothing to compare with.”**
Commit the snapshots once; from then on vs develop compares with the base branch.

**Re-records with no visible change clutter my pull request.**
Use **Discard…** in Working Copy: it restores every uncommitted snapshot whose difference is invisible.

## Remote runs

**“Cannot reach ci-mac over SSH”** — SnapshotKit uses key-based login only. `ssh ci-mac true` must work
without a password prompt; set up a key with `ssh-copy-id ci-mac`.

**Messages starting with “On ci-mac:”** — an Xcode or simulator problem on the remote Mac; the fixes above
apply there.

## The diff tool

**`snapkit open` says “Couldn’t open SnapshotKit”.**
Install SnapshotKit.app in `/Applications`, or tell it where the app is with `--app PATH` or `SNAPSHOTKIT_APP`.

**The command from the failure message prints “usage: snapkit open …” or “no such file”.**
A path contains a space and isn’t quoted. That happens when the diff tool is the plain string `"snapkit open"`:
swift-snapshot-testing appends the paths to a string unquoted. Define the tool with a closure that quotes them,
as in [Set it up](diff-tool.md#set-it-up).

## Where to report a problem

Open an issue at [github.com/TobiasRe/SnapshotKit/issues](https://github.com/TobiasRe/SnapshotKit/issues) with
what you did, what you expected, the message you got and, for a run, the output of `snapkit config`.
