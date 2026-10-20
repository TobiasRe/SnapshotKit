# Re-recording

Re-recording replaces reference images with what the tests render now. swift-snapshot-testing only records
when a test asks it to, so normally you'd edit the test (`record: .all`), run it, and remember to undo the
edit. SnapshotKit does that for you: it switches record mode on in the test source, runs exactly the tests you
chose the way CI runs them, switches it off again — always — and then runs them once more to verify the new
references.

## What you can re-record

| What | Where | Shortcut |
|---|---|---|
| The selected test | camera button in a detail header; Snapshots › Re-record Selected Test | ⇧⌘R |
| The selected test's whole suite | the camera button's arrow › Re-record Suite *name* | |
| The failing suites of the last run | **Re-record All** in the Failures header; the Run button's arrow › **Re-record Failing Suites**; **Re-record Failed** on the Run tab; Snapshots › Re-record Failing Suites | ⌥⇧⌘R |
| What the library shows | the library footer's **Re-record All…** / **Re-record N Shown…** (filter first, e.g. `dark`) | |
| Every snapshot test in the project | the Run button's arrow › **Re-record All Snapshot Tests…**; Snapshots menu; ⌘K | |
| A test from a change or failure | its ··· menu or right-click | |
| On the CI machine | Run tab › ··· › On *host* › Re-record Failed. [Remote runs](remote-runs.md) | |

Re-recording more than ten tests asks first, with the number of tests. Orphaned snapshots can't be re-recorded:
their test no longer exists.

## What happens, step by step

The Run tab and the notice follow each stage:

1. **Finding suite sources** — the test file of each snapshot: `<suite folder>.swift`, preferring the one
   next to the `__Snapshots__` folder, then the test type in it (named like the file, or the first type ending
   in `Tests`).
2. **Enabling record mode** — the test type is patched (below). SnapshotKit refuses if one of those files has
   uncommitted changes: *Refusing to re-record: these files have uncommitted changes. Commit or stash them
   first.* That way your own edits can never get mixed up with the patch.
3. **Recording snapshots** — `xcodebuild test` runs, limited with `-only-testing` to the chosen tests. Every
   snapshot those tests take is written to disk.
4. **Restoring test sources** — the patch is removed.
5. **Verifying new references** — the same tests run again, unpatched. If they pass, the notice says
   *Re-recorded payButton. Verified: 2 passed.* If they still fail, it says so: the test may be flaky (try
   [Check Flakiness](failures.md#checking-for-flakiness)). Turn verification off under Settings › Verify
   after re-recording.

The new PNGs are now uncommitted changes. Review them on the [Changes](changes.md) tab — *Discard…* drops the
ones with no visible change — and commit.

## The patch

A line SnapshotKit inserts ends with the marker comment `// snapshotkit:record`, so it's easy to spot. An
existing `@Suite` attribute is edited in place instead and gets no marker.

**Swift Testing** — record mode is set through the suite's `.snapshots` trait:

```swift
// No @Suite yet: one is added above the type, with the marker
@Suite(.snapshots(record: .all)) // snapshotkit:record
struct CheckoutViewTests { … }

// @Suite without arguments: edited in place
@Suite(.snapshots(record: .all))

// @Suite(.serialized): the trait is appended
@Suite(.serialized, .snapshots(record: .all))

// An existing .snapshots(diffTool: …): record is added; an existing record: value is replaced
@Suite(.snapshots(record: .all, diffTool: .ksdiff))
```

**XCTest** — an `invokeTest` override is added to the test case:

```swift
final class CheckoutViewTests: XCTestCase {
    override func invokeTest() { withSnapshotTesting(record: .all) { super.invokeTest() } } // snapshotkit:record
    …
}
```

A test case that already overrides `invokeTest()` can't be patched this way; SnapshotKit says so and you
re-record it by hand.

Granularity: when you re-record *tests*, `-only-testing` names each test (`Bundle/Suite/test()` for Swift
Testing, `Bundle/Suite/test` for XCTest), so only those run. Parameterized tests, and tests whose function
can't be found, run with their whole suite. *Re-record Suite* and *Re-record Failed* run whole suites.

## Always restored

The patch is never left behind:

| When | What happens |
|---|---|
| The run ends, fails or throws | the sources are restored before anything else. |
| You cancel (⌘., Cancel) | the run stops and the sources are restored. |
| You quit SnapshotKit | restored on quit. |
| `snapkit` gets Ctrl-C, SIGTERM, SIGHUP or SIGQUIT | child processes are stopped, sources restored, then it exits. The first Ctrl-C cancels gracefully; a second forces it. |
| The app or `snapkit` crashes, or the Mac restarts | the next launch of either restores it: *Restored a record patch left by an interrupted run.* |

How it works: before touching a file, SnapshotKit writes a journal to `.git/snapshotkit/record-patch.json` with
each file's original and patched text (and registers the repository in `active-patches.json` in its settings
folder). Restoring compares each file with the journal:

- still the patched text → the original is written back,
- already the original → nothing to do,
- you edited the file during the run → only the patch lines are swapped back and **your edits are kept**,
- changed so much the patch can't be found → the original is saved to
  `.git/snapshotkit/backups/<path>.orig` and you're told: *could NOT restore … automatically; original saved
  at …*.

A patch owned by a SnapshotKit or `snapkit` process that's still running is left alone, so two runs can't
undo each other. `snapkit restore` restores a project by hand; `--force` overrides that check.

## Recording on another machine

References recorded on your Mac can differ invisibly from what CI renders (another GPU, OS or Xcode), and CI
then fails with *Invisible* differences. Record where CI compares: see [Remote runs](remote-runs.md). The
remote copy is patched instead of your files, and only the new PNGs come back.

## From the command line

```bash
snapkit record CheckoutViewTests dark     # tests whose snapshot paths contain both words
snapkit record payButton --whole-suite    # their whole suites
snapkit rerecord                          # the last run's failing suites
snapkit rerecord --suite AppSnapshotTests/CheckoutViewTests
snapkit rerecord --remote                 # on the remote machine
snapkit restore                           # restore a leftover patch by hand
```

See [the CLI reference](cli.md).
