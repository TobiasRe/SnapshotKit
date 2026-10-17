# Using SnapshotKit as your diff tool

When a snapshot test fails, swift-snapshot-testing ends the failure message with a command for your *diff
tool*, given the reference image and the image the test produced. Name `snapkit open` as that tool and the
command opens the pair in a SnapshotKit compare window.

> `snapkit open` and the compare window need SnapshotKit 0.1.1 or later. `snapkit diff` (below) works with every
> version.

## Set it up

Install SnapshotKit.app and put `snapkit` on your `PATH` ([Getting started](getting-started.md)). Then name the
tool in your tests.

**Swift Testing** — on a suite, or on a base suite that your snapshot suites nest in:

```swift
import SnapshotTesting
import Testing

@Suite(.snapshots(diffTool: "snapkit open"))
struct CheckoutViewTests {
    @Test func payButton() {
        assertSnapshot(of: PayButton(), as: .image)
    }
}
```

**XCTest** — in a base class your test cases inherit from:

```swift
import SnapshotTesting
import XCTest

class SnapshotTestCase: XCTestCase {
    override func invokeTest() {
        withSnapshotTesting(diffTool: "snapkit open") {
            super.invokeTest()
        }
    }
}
```

A string literal works as a `DiffTool`: swift-snapshot-testing appends the two paths, quoted.

## What you get

A failure message now ends like this:

```
Snapshot does not match reference.

snapkit open "/…/__Snapshots__/CheckoutViewTests/payButton.png" "/…/tmp/payButton.png"
```

Copy the line into Terminal (in Xcode, from the issue in the Report navigator). `snapkit` prints the diagnosis —

```
1468 pixels differ (0.436%), largest ΔE 85.3
Visible change in a 105×58 area at 847, 136.
```

— and SnapshotKit opens a window with the pair: Side by Side, Slider, Difference and Toggle, zoom, the pixel
readout and the diagnosis note, as in the [compare view](comparing.md).

Its header shows the test and variant and where the reference lives (*Shop › ShopTests › ProductCardTests*),
with:

- **Show in Project** — opens the repository in SnapshotKit (adding it if needed) and selects the snapshot in
  its library, ready to re-record. Shown when the reference is inside a git repository.
- **Reveal in Finder** — both images.

Opening the same pair again brings its window forward; each new pair gets its own window.

## Terminal only: `snapkit diff`

If you'd rather not leave the terminal, name `snapkit diff` instead:

```swift
@Suite(.snapshots(diffTool: "snapkit diff"))
```

The command then prints the summary and, for invisible or tiny differences, the precision that would pass.
Append `-o diff.png` to write the difference image.

## Which app opens

`snapkit open` opens, in order of preference:

1. the app given with `--app PATH`,
2. the app in `SNAPSHOTKIT_APP`,
3. the installed SnapshotKit.app (by its bundle id `org.snapshotkit.SnapshotKit`).

Use `--app` or `SNAPSHOTKIT_APP` for a development build, e.g.
`.snapshots(diffTool: "snapkit open --app ~/Developer/SnapshotKit/dist/SnapshotKit.app")`.

## From other tools: `snapshotkit://`

The app opens compare windows for links of this form:

```
snapshotkit://compare?reference=<absolute path>&actual=<absolute path>
```

with the paths percent-encoded. `open "snapshotkit://compare?…"` in a script, a link in a CI report viewed on the
same Mac, or another tool can use it. Links with any other form are ignored.

## Notes

- swift-snapshot-testing only puts the command into the message; nothing runs automatically during tests.
- The actual image lives in a temporary folder of the test run. Open it soon, or it may be cleaned up.
- The window compares files; it doesn't need the project to be added to SnapshotKit, and nothing is changed.
