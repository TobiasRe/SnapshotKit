# Projects and scanning

A *project* in SnapshotKit is a git repository with snapshot tests. This page covers adding projects,
scan folders, the sidebar, the ⌘K palette and the settings that apply to all projects.

## What counts as a project

A git repository is a project when any of these is true:

- it has a `.snapshotkit.yml` at its root,
- it contains files in `__Snapshots__` folders, committed or not yet (anything `git ls-files` lists, including
  untracked files that aren’t ignored),
- one of its files names `swift-snapshot-testing` (`Package.swift`, `Package.resolved`, an Xcode project),
  even if no test has recorded a snapshot yet.

A project with no snapshots yet opens on an empty library with a **Run Tests** button that records the first
ones.

## Adding projects

| How | What happens |
|---|---|
| **File › Add Project…** (⌘O) | Choose any folder inside a repository; the repository’s root is added and opened. |
| Sidebar **+** › **Add Project…** | The same. |
| Drop a repository folder onto the window | Added and opened. |
| Sidebar **+** › **Add Scan Folder…** | Choose a folder that contains repositories; it is scanned now and on every **Rescan Folders**. |
| Drop any other folder onto the window | Added as a scan folder and scanned. |
| ⌘K, type a path | Projects match by name and by path. |

## Scan folders

A scan folder is searched for projects up to **six folders deep**. To stay fast on a whole home folder,
scanning skips:

- hidden folders,
- bundles and packages: `.app`, `.xcodeproj`, `.xcworkspace`, `.xcassets`, `.bundle`, `.framework`, and
  anything macOS treats as a package (such as a Photos library),
- dependency and build folders: `node_modules`, `Pods`, `Carthage`, `DerivedData`, `.build`, `build`,
  `vendor`,
- folders named `Library`, `Applications`, `Music`, `Movies`, `Pictures` or `Public` (at any level, not only
  in the home folder),
- the inside of a repository once it is found (nested repositories aren’t searched).

Scanning `~` typically takes a few seconds.

After every scan a notice says what was found: how many projects in which folders, that none were found (and
what makes a repository count), or that macOS denied access. If access was denied, allow SnapshotKit in
System Settings › Privacy & Security › Files and Folders (or Full Disk Access) and choose **Rescan Folders**.

Scan folders are listed in **Settings › Scan Folders**, where you can add, remove and rescan them. Projects
found by a scan stay listed until you remove them, as do projects you added yourself: a rescan only adds the
projects it finds.

## The sidebar

The sidebar has up to three sections:

- **Pinned** — projects you pinned (right-click › Pin). Always at the top.
- **Recent** — the projects you opened most recently, newest first (up to ten).
- **Projects** — every project, alphabetically. A project stays in its place here when you open it; Pinned
  and Recent are shortcuts to the same projects.

Each row shows the project’s initials, its name and, after a run with failures, a red dot with the number of
failing tests. Hover a row for its full path. Right-click for **Pin**/**Unpin**, **Reveal in Finder** and
**Remove from List** (which only removes it from SnapshotKit, never from disk); for the open project, ⌘K
offers the same.

The **+** menu at the bottom adds projects and scan folders and rescans; the **⌘K** button opens the
palette.

## The ⌘K palette

⌘K (File › Go to Project or Command…) opens a palette over the window. Type to filter; ↑/↓ to move; Return
to choose; Escape to close.

- **Projects** match by name first, then by path. The current project is labeled *Current*, others show
  their folder.
- **Commands** act on the open project, each with its keyboard shortcut where it has one: Run Snapshot
  Tests, Run on Remote Machine, Re-record Selected Test, Open Test in Xcode, Re-record Failing Suites, Check
  Flakiness of Failing Tests, Re-record All Snapshot Tests…, Cancel Run, Show Snapshots/Changes/Failures/Run,
  Import Result Bundle…, Refresh Changes, Mark All Changes as Viewed, Pin/Unpin Project, Reveal Project in
  Finder, Remove Project from List and Add Project…. A command that can’t do anything now (nothing failing,
  no remote machine, everything viewed, a run in progress) is left out.

Matching is fuzzy: `rrf` finds *Re-record Failing Suites*, `pay` finds *payments-ui*.

## The window

SnapshotKit has one main window. A project shows in it with a toolbar and four tabs:

| Tab | Shortcut | What it shows |
|---|---|---|
| **Snapshots** | ⌥⌘1 | The library: every reference image. [Details](library.md) |
| **Changes** | ⌥⌘2 | Snapshots that differ from the base branch. [Details](changes.md) |
| **Failures** | ⌥⌘3 | Failing snapshots from the last run or an imported `.xcresult`. [Details](failures.md) |
| **Run** | ⌥⌘4 | Configuration, runs, live output and results. [Details](running.md) |

The tab labels carry counts: *Snapshots (26)*, *Changes (16)*, *Failures (3)*. The window title is the project
name; the subtitle is the current branch and, when it isn’t the base branch, the base branch it is compared
with (`feature/checkout → develop`).

Besides the tabs, the toolbar holds **Run** (▶, ⌘R): run the snapshot tests the way CI does. Its arrow offers
**Re-record Failing Suites** and **Re-record All Snapshot Tests…**. While a run is going, it becomes
**Cancel** (⌘.). To re-record the selected test, use the camera button in its detail header, or ⇧⌘R from
anywhere.

There is no second main window to open (only the compare windows of the [diff tool](diff-tool.md)). Closing
the last window quits SnapshotKit, unless the [menu bar item](menu-bar.md) is on: then it keeps running, and
the Dock icon or the menu bar item brings the window back.

The list column on the left of Snapshots, Changes and Failures has one width shared by all three tabs; drag
the divider to change it.

## Notices

When something finishes — a run, a re-record, a scan — a notice floats at the bottom right of the window
with the outcome and, where there is one, the next step (*Show Failures* after a failing run, *Review Changes*
after a re-record). It fades after a few seconds unless it reports a problem. Notices never push the panes
around.

## Live updates

While a project is open, SnapshotKit watches its `__Snapshots__` folders. When a test re-records images from
Xcode or the command line, the library and the Changes tab update by themselves. When you come back to
SnapshotKit from another app, the changes are refreshed too.

## Settings

**SnapshotKit › Settings…** (⌘,):

| Setting | Default | What it does |
|---|---|---|
| Show in menu bar | off | Adds the [menu bar item](menu-bar.md). SnapshotKit then keeps running when its window is closed. |
| Scan Folders | none | Folders searched for projects, with **Rescan Folders** and **Add Scan Folder…**. |
| Flakiness check runs | 5 | How many times **Check Flakiness** runs the failing tests (2–50). |
| Verify after re-recording | on | After recording new references, run the same tests again to confirm they pass. |
| Settings file | | **Show in Finder** reveals `settings.json`. |

Per-project choices — the base branch, the remote host and the test target — are made on the Run tab and
the Changes tab and stored in the same file. See [Configuration](configuration.md).
