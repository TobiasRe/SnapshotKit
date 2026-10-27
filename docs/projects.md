# Projects and scanning

A *project* in SnapshotKit is a git repository with snapshot tests. This page covers adding projects,
scan folders, the sidebar and its sections, the ⌘K palette and the settings that apply to all projects.

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
| Project switcher › **Add Project…** | The same. |
| Drop a repository folder onto the window | Added and opened. |
| Project switcher › **Add Scan Folder…** | Choose a folder that contains repositories; it is scanned now and on every **Rescan Folders**. |
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

The sidebar shows one project at a time: the project switcher at the top, and the project’s sections under
it.

### The project switcher

The switcher shows the project’s name and the checked-out branch. Click it to open another project:

- **Find a project** — type to filter; ↑/↓ and Return work from the field.
- **Pinned** — projects you pinned (right-click › Pin).
- **Projects** — every project, alphabetically.
- **Add Project…**, **Add Scan Folder…** and, when you have scan folders, **Rescan Folders**.

Each project shows its initials and name and, after a run with failures, a red dot with the number of failing
tests. Hover a project for its full path. Right-click a project
for **Pin**/**Unpin**, **Reveal in Finder** and **Remove from List** (which only removes it from SnapshotKit,
never from disk); for the open project, ⌘K offers the same.

### Sections

The sections come in three groups: Workspace, Tests and Library.

| Section | Shortcut | What it shows |
|---|---|---|
| **Working Copy** | ⌥⌘1 | Snapshots changed and not committed yet: modified, new or deleted. [Details](changes.md) |
| **vs develop** | ⌥⌘2 | Every snapshot this checkout changes compared with the base branch, committed or not. [Details](changes.md) |
| **Last Run** | ⌥⌘3 | Failing snapshots from the last run or an imported `.xcresult`. [Details](failures.md) |
| **Run** | ⌥⌘4 | Configuration, runs, live output and results. [Details](running.md) |
| **All Snapshots** | ⌥⌘5 | The library: every reference image. [Details](library.md) |
| **Orphaned** | ⌥⌘6 | Snapshots no test records any more; listed only while there are some. [Details](library.md#orphaned-snapshots) |

**vs develop** is named after the base branch; its full name, in the window title, the menus and VoiceOver,
is *Changes vs develop*. When the failures were loaded from a GitLab CI job, **Last Run** is named after the
job instead: *CI · snapshotTest #4567* (in full, *CI Job snapshotTest #4567*).

Each section carries its count as a badge: Working Copy’s with an orange dot, Last Run’s with a red one.

## The ⌘K palette

⌘K (File › Go to Project or Command…) opens a palette over the window. Type to filter; ↑/↓ to move; Return
to choose; Escape to close.

- **Projects** match by name first, then by path. The current project is labeled *Current*, others show
  their folder.
- **Commands** act on the open project, each with its keyboard shortcut where it has one: Run Snapshot
  Tests, Run on Remote Machine, Re-record Selected Test, Open Test in Xcode, Re-record Failing Suites, Check
  Flakiness of Failing Tests, Re-record All Snapshot Tests…, Cancel Run, Show Working Copy, Show Changes vs
  develop, Show Last Run, Show Run, Show All Snapshots, Show Orphaned Snapshots, Import Result Bundle…, Refresh
  Changes, Mark All Changes as Viewed, Pin/Unpin Project, Reveal Project in Finder, Remove Project from List
  and Add Project…. A command that can’t do anything now (nothing failing,
  no remote machine, everything viewed, a run in progress) is left out.

Matching is fuzzy: `rrf` finds *Re-record Failing Suites*, `pay` finds *payments-ui*.

## The window

SnapshotKit has one main window. A project shows in it with the [sidebar](#the-sidebar) on the left and the
open section on the right. A project opens on All Snapshots.

The window title is the open section’s name (*Working Copy*, *Changes vs develop*); the subtitle is the project
and its branch (`payments-ui · feature/checkout`).

The toolbar holds **Run** (▶, ⌘R): run the snapshot tests the way CI does. Its arrow offers **Re-record
Failing Suites** and **Re-record All Snapshot Tests…**. While a run is going, it becomes
**Cancel** (⌘.). To re-record the selected test, use the camera button in its detail header, or ⇧⌘R from
anywhere.

There is no second main window to open (only the compare windows of the [diff tool](diff-tool.md)). Closing
the last window quits SnapshotKit, unless the [menu bar item](menu-bar.md) is on: then it keeps running, and
the Dock icon or the menu bar item brings the window back.

The list column on the left of every section with a list has one width shared by all of them; drag the
divider to change it.

## Notices

When something finishes — a run, a re-record — a notice floats at the bottom right of the window with the
outcome and, where there is one, the next step (*Show Failures* after a failing run opens Last Run, *Review
Changes* after a re-record opens Working Copy). It fades after a few seconds unless it reports a problem. A
scan’s result floats at the bottom center until you close it. VoiceOver reads both out. Notices never push
the panes around.

## Live updates

While a project is open, SnapshotKit watches its `__Snapshots__` folders. When a test re-records images from
Xcode or the command line, the library, Working Copy and vs develop update by themselves. When you come back to
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

Per-project choices — the base branch, the remote host and the test target — are made in Run and in
the branch menu of vs develop, and stored in the same file. See [Configuration](configuration.md).
