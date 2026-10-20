# Remote runs

Snapshot images depend on the machine that renders them: the GPU, the macOS version, the Xcode and simulator
runtime. A reference recorded on your laptop can fail on CI with an *Invisible* difference, and the other way
round. The reliable fix is to record on the machine CI uses. SnapshotKit can run, re-record and check
flakiness **on another Mac over SSH**, with your working tree, and bring the new references back.

## Requirements

On your Mac:

- SSH access to the remote Mac with **key-based login**. SnapshotKit never asks for passwords
  (`BatchMode=yes`). Check with `ssh <host> true`.
- `rsync` (part of macOS).

On the remote Mac:

- the Xcode version your CI uses, installed as `/Applications/Xcode*.app` or `~/Applications/Xcode*.app`,
- the simulator runtime and device your CI uses,
- `bash` and `rsync` (part of macOS).

Nothing else needs installing there: no SnapshotKit, no `snapkit`.

## Configuring the host

Set the host in one of two places (the project setting wins):

- **Run tab › Comparison & Remote › Remote host** — stored only for you, in your settings. Hosts are often
  personal, so this is the usual place.
- **`remoteHost:` in `.snapshotkit.yml`** — shared with everyone who uses the repository.

The value is anything `ssh` accepts: `user@ci-mac.local`, or an alias from `~/.ssh/config`. Optionally set
`remoteDirectory:` in `.snapshotkit.yml` for where the working copy lives on the remote Mac; the default is
`~/.snapshotkit/workspaces/<repository>-<hash>`.

## What a remote run does

1. **Checking remote Xcode and simulator** — the same checks as locally, on the remote Mac. Problems are
   reported as *On ci-mac: Xcode 16.2 is not installed …*.
2. **Syncing working tree** — your tracked files plus untracked files that aren't ignored (`git ls-files -co
   --exclude-standard`) are copied with `rsync`, including uncommitted changes. Files you deleted are deleted
   there too, except build products (`.build`, `.swiftpm`, `DerivedData`, `.snapshotkit`).
3. **Running tests remotely** — `xcodebuild test` with the CI configuration, over `ssh -tt`, so canceling here
   stops it there. The output streams into the Run tab.
4. **Collecting results** — the result summary and failure images are fetched, and remote paths are mapped back
   to your repository, so the Failures tab works as for a local run.

The run is recorded in the history with the host's name, so the strips and the flakiness signal include
remote runs.

## Re-recording remotely

**Run tab › ··· › On *host* › Re-record Failed** (or `snapkit rerecord --remote`):

- Your files are **never patched**. The record patch is applied to the remote copy only, and the original sources
  are put back there after the run.
- Every `__Snapshots__` file the run wrote is downloaded into your working tree at the same path (*Downloaded 3
  snapshots recorded on ci-mac.*).
- Review them on the Changes tab and commit, as with a local re-record.

## Checking flakiness remotely

**Run tab › ··· › On *host* › Check Flakiness** (or `snapkit flaky --remote`) repeats the failing tests on the
remote Mac. A test that fails on CI but passes on your Mac often shows its true colors there.

## A local "remote"

`remoteHost: local` runs the same remote flow against a directory on this Mac, which is useful for trying it
out and for tests.

## Errors

| Message | Fix |
|---|---|
| *No remote machine configured. Set `remoteHost:` in .snapshotkit.yml or in the project's settings.* | set a host (above). |
| *Cannot reach ci-mac over SSH (…). Check that key-based login works: `ssh ci-mac true`.* | set up an SSH key for the host (`ssh-copy-id`), or fix the host name. |
| *On ci-mac: …* | an Xcode or simulator problem on the remote Mac; see [Troubleshooting](troubleshooting.md). |
| *Copying files to/from ci-mac failed: …* | check disk space and permissions of the remote directory. |

## From the command line

```bash
snapkit run --remote                  # the configured host
snapkit run --remote ci-mac           # another host, this once
snapkit rerecord --remote             # record the failing suites there, download the PNGs
snapkit flaky --remote --iterations 10
```
