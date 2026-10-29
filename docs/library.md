# The snapshot library

**All Snapshots** (⌥⌘5) is the library: every reference image in the project, the way your tests named
them. Use it to find a snapshot, inspect it pixel by pixel, compare it with its other variants or an earlier
commit, and re-record it.

![The snapshot library](images/library.png)

## How snapshots are named and grouped

swift-snapshot-testing stores each reference as
`<test target>/__Snapshots__/<test file>/<test name>.<variant>.png`, for example
`ShopTests/__Snapshots__/CheckoutTests/payButton.dark.png`. SnapshotKit reads that path as:

| Part | Example | Where it shows |
|---|---|---|
| Module (test target) | `ShopTests` | section headers (`ShopTests › CheckoutTests`) and the breadcrumb |
| Suite (test file) | `CheckoutTests` | section headers |
| Test name | `payButton` | the row title |
| Variant | `dark` | on the line under the title, in code type: the `named:` argument or the counter (`1`, `2`…) |

Variants of one test (`payButton.dark`, `payButton.light`) sit next to each other, in the order Finder sorts
their names (`dark` before `light`, `2` before `10`).

## Finding snapshots

**Filter** (⌘F): type to filter by module, suite, test or variant. Every word must match somewhere, so
`checkout dark` finds the dark variants of the checkout tests. Escape clears the filter, a second Escape
leaves the field.

The filter field sits at the top of the list, with the **Sort** menu and the **List**/**Grid** switch under
it. The sidebar’s other sections each show a part of the library: **vs develop** what differs from the base
branch, **Last Run** what failed, **Working Copy** what isn’t committed, and **Orphaned** (⌥⌘6) what no test
records any more. See [Sections](projects.md#sections).

**Sort** (the ⇅ button): **Name** groups by module and suite; **Size** (largest first) and **Recently
Changed** show one flat list, useful for finding oversized images or what was recorded last.

**Layout**: a **list** with a large preview of the selected snapshot, or a **grid** of thumbnails. In the grid,
click a tile to select it and double-click (or press Return) to open it large; the arrow keys move the
selection, Space Quick Looks it and ⌘C copies it, as in the list.

![The library as a grid of thumbnails](images/library-grid.png)

## Rows and tiles

Each row (and each grid tile) has a thumbnail, the test name and one quiet status line: what’s notable about
the snapshot, then its variant, for example *● Uncommitted · dark*. The line names one state at most, with a
colored dot:

- **Orphaned** — its test no longer exists,
- otherwise its change against the base branch: **Changed** (committed on this branch; vs develop calls it
  *Committed*), **Uncommitted**, **New** or **Deleted**,
- otherwise an edit git hasn’t committed: **Modified** or **New**.

A snapshot with nothing notable shows just its variant. Only failing gets a mark of its own, at the trailing
edge (on a tile, its top corner): a red ✕ when its test failed in the last run, an orange ⚠ when it is flaky.

A test’s variants are listed under one title. A counter variant (`1`) is left out when it is a test’s only
image; a named one (`dark`) always shows.

## The detail

Selecting a snapshot shows it large on the right.

**Header** — the test name and variant, the breadcrumb (`ShopTests › CheckoutTests`), status chips, and the
actions. The chips are **Failing** (or **Flaky**) when its test failed in the last run, and the same word as the
row’s status line (*Uncommitted*, *New*, *Orphaned*…). Click **Failing** to compare it with the actual image in
Last Run (or the CI job), or a change’s chip to review it in Working Copy when it isn’t committed, else in vs
develop.

- **Re-record** (camera): records this test again, then verifies it. Its arrow offers **Re-record Test** and
  **Re-record Suite** (every test in the file). See [Re-recording](re-recording.md).
- **···**: Re-record *test*, Re-record Suite *suite*, Open Test in Xcode (⌥⌘O, at the test function), Open in
  Default App, Reveal in Finder, Copy Image, Copy Path, and Move to Trash for orphaned snapshots.
- **12 / 40** with arrows (⌥⌘↑ / ⌥⌘↓): where you are in the list, and the way through it.

**Info row** — the snapshot’s history from git: how many committed versions it has, and when, by whom and in
which commit it was last changed. Next to it:

- the **variant** switch (dark / light, iPhoneSE / iPhone13ProMax…), when the test has several: up to three
  side by side, more in a menu that names the one shown,
- **Compare with…**: compare this snapshot side by side (or in any [compare mode](comparing.md)) with one of
  its other variants or with any earlier committed version.

**Viewer** — the image on a checkerboard (so transparency shows), with its pixel size and file size and the
zoom controls. Pinch or ⌘= / ⌘− to zoom, drag to pan, double-click or ⌘0 (Zoom to Fit) to fit. Hover to read
the pixel under the pointer.

## Working with snapshots

| To | Do |
|---|---|
| Quick Look the selected snapshot | Space (in the list) |
| Copy the image | ⌘C (in the list), or ··· › Copy Image |
| Put snapshots in a document, a ticket or a chat | drag rows or tiles out of the list |
| Open the test that records it | ⌥⌘O, or ··· › Open Test in Xcode. Xcode opens the test file at the test function. |
| Re-record what the list shows | the footer’s **Re-record All** (or **Re-record N Shown** when filtered; with “…” when it asks first). Filter first to narrow it down, e.g. every `dark` variant. More than ten tests asks first. |
| Clean up orphans | **Orphaned** in the sidebar, then the footer’s **Move N to Trash…**. Committed files stay recoverable through git, all of them from the Trash; commit the deletion to remove them from the repository. |

The footer counts what the library holds: snapshots, tests, modules and total size.

## From a test in Xcode to its snapshots

The way back from ⌥⌘O: in Xcode, select the name of a test function (or of a test struct or class) in the
editor, right-click it and choose **Services › Open in SnapshotKit**. SnapshotKit opens the project with
those snapshots in **All Snapshots**:

- a test's snapshots: the first one selected, its variants in the detail;
- a test file's (the selected name is a type, or no test is called that): the list filtered to it;
- the same test name in several test files: the list filtered to the name.

It looks in the open project first, then in your other projects. Selecting `payButton`,
`@Test func payButton()` or the whole declaration line all work, for parameterized tests too. When nothing is
found, the window says so.

The item is in the Services menu of every app (the app menu › Services, too), wherever text is selected.
Give it a shortcut in System Settings › Keyboard › Keyboard Shortcuts › Services › Text, or turn it off there.
It needs SnapshotKit.app installed; if it doesn't appear after the first launch, log out and back in once.

## Orphaned snapshots

A snapshot is orphaned when no test in its test file records that name any more — typically after a test
was renamed or deleted, or a variant was dropped. Orphans can’t be re-recorded (there’s no test to run).
While there are some, the sidebar lists them under **Orphaned** (⌥⌘6), with their count. They are found by
reading the test sources, so a test that builds its snapshot names dynamically may be flagged by mistake;
check before trashing.
