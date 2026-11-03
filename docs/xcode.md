# Working with Xcode

SnapshotKit works beside Xcode rather than inside it, and the two hand work to each other:

- **Test runs in Xcode show up in SnapshotKit.** When a run finishes, its results join Last Run.
- **Xcode’s Editor menu reaches SnapshotKit.** With the cursor in a test, **Editor › SnapshotKit › Show Test**
  or **Re-record Test**.
- **SnapshotKit opens tests in Xcode.** **Open Test in Xcode** (⌥⌘O) opens a snapshot’s test file at its
  function; see [The snapshot library](library.md).
- **Failure messages open in SnapshotKit**, with `snapkit open` as swift-snapshot-testing’s diff tool; see
  [Using SnapshotKit as your diff tool](diff-tool.md).

## Test runs in Xcode

Run tests in Xcode as you always do: ⌘U, a test’s diamond, **Test Again**. When the run finishes, SnapshotKit
reads its result bundle, and the tests it ran replace their results in **Last Run**, as a run of the same tests
in SnapshotKit would. Running one test in Xcode updates that test; the other failures stay as they were.

A notice says how it went: *Xcode: 1 failing test in 1 suite.* with **Show Failures**, or *Xcode: 12 tests
passed.* SnapshotKit stays on the section you were looking at. Last Run’s header shows *Xcode* as where the
tests ran, the Dock badge counts the failures, and the run joins the [run history](failures.md#run-history)
with its commit, as a local run does.

This needs no setup:

- SnapshotKit watches Xcode’s DerivedData folder, in the place set in Xcode › Settings › Locations. Each
  project there names the workspace or package it builds, and SnapshotKit takes the runs of those inside an open
  project’s repository (a project in a subfolder, such as `Example/Shop.xcodeproj`, included).
- It watches the projects opened since SnapshotKit started. A run that finished before then isn’t taken up; to
  look at one, choose **Import Result Bundle…** (⇧⌘O) and open it from DerivedData’s `Logs/Test` folder.
- While SnapshotKit runs or re-records tests itself, runs in Xcode finishing meanwhile aren’t taken up: that run
  says what the last run is.
- `xcodebuild` with `-resultBundlePath` (SnapshotKit’s own runs, `snapkit`, most CI scripts) writes its bundle
  where it is told, not into DerivedData, so those runs never arrive twice.

## The editor extension

SnapshotKit.app contains an Xcode Source Editor extension that adds **Editor › SnapshotKit** to Xcode.

### Turn it on

1. Open SnapshotKit once, from the Applications folder, so macOS finds the extension inside it.
2. In System Settings › General › Login Items & Extensions, under Extensions, open **Xcode Source Editor** and
   turn on **SnapshotKit**. On macOS 14, it is in System Settings › Privacy & Security › Extensions.
3. Quit Xcode and open it again.

To give the commands shortcuts, search for *SnapshotKit* in Xcode › Settings › Key Bindings.

### The commands

| Command | What it does |
|---|---|
| **Show Test** | Brings SnapshotKit forward on the test: its failure in Last Run when it is failing, else its first snapshot in All Snapshots. |
| **Re-record Test** | Re-records the test, then verifies, as **Re-record Selected Test** does in SnapshotKit. |

With the cursor in a test suite but outside its tests, both act on the whole suite: Show Test filters All
Snapshots to it, Re-record Test re-records all of its tests.

**Which test.** The test function around the cursor (the line that declares it counts), in the innermost type
around it. Its snapshots are found by swift-snapshot-testing’s naming: the folder named after the test file,
which by convention is named after the suite, and the file named after the function. A test with no snapshots
yet says so: run it once, and swift-snapshot-testing records them.

**Which project.** The one Xcode has in front, which SnapshotKit asks Xcode about, adding and opening it if it
isn’t open yet. The first time, macOS asks whether SnapshotKit may control Xcode; this is all it asks Xcode. If
you don’t allow it, SnapshotKit uses the project open in its window. You can change your answer in System
Settings › Privacy & Security › Automation.

An extension sees only the text of the file it acts on, not where the file is or what else Xcode has open. It
runs in a sandbox and passes the test to SnapshotKit as a link, `snapshotkit://test?action=show&suite=…&function=…`,
which you can also open yourself, from a script or a note.
