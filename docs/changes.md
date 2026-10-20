# Reviewing changes

The **Changes** tab (⌥⌘2) lists every snapshot image that differs from your base branch — committed on this
branch or not yet — and shows each one before and after. Review them the way you review code: one by one,
marking each as viewed.

![Changes compared with the base branch](images/changes-dark.png)

## What counts as a change

SnapshotKit compares the PNG files in your working tree (including new files git doesn't track yet, unless
they're ignored) with the base branch:

| Kind | Meaning |
|---|---|
| **Committed** | changed in a commit on this branch |
| **Uncommitted** | changed in the working tree (staged or not), e.g. just re-recorded |
| **New** | added on this branch, or a new file not committed yet |
| **Deleted** | removed on this branch |

Each change carries its kind as a coloured dot and label, and the row shows the variant like the library does.

## The base branch

The base branch is found in this order (see [Configuration](configuration.md#the-base-branch) for details):

1. the base branch you chose in the branch menu (stored per project),
2. `baseBranch` in `.snapshotkit.yml`,
3. the target branch your CI uses for merge requests or pull requests,
4. `origin/HEAD`, else the first of `develop`, `main` and `master` that exists.

`origin/<branch>` is preferred over a local branch of the same name, so fetch to compare with the latest
state. If the branch doesn't exist, the tab says so: *Base branch 'x' was not found locally or on origin.
Fetch it or choose a different base branch.*

The filter bar has three menus:

- **Branch** (⑂ `develop`): pick another base branch, or **Use Detected Branch** to go back to automatic.
- **Merge-base / Branch tip**: compare with the point where your branch left the base branch (the default:
  only your branch's changes, what a pull request shows), or with the base branch's current tip (also shows
  what changed there since you branched).
- **Kinds** (*All*): show or hide Committed, Uncommitted, New and Deleted; **Hide Viewed**; **Mark All as
  Viewed** / **Mark All as Not Viewed**.

↻ (Refresh) compares again. It also happens by itself when snapshot files change on disk and when you return
to SnapshotKit from another app.

## Reviewing a change

Select a change to see it in the [compare view](comparing.md): the base branch on the left (or under the
slider), this branch or the working tree on the right.

The detail header shows the test name and variant, its breadcrumb, its kind, and:

- **Viewed** — mark it reviewed (V in the list, ⌥⌘V anywhere). ⌥⌘V also moves to the next change, so you
  can go through a branch with one shortcut.
- **···** — Re-record the test, Show in Library, Open Test in Xcode, Open in Default App, Reveal in Finder,
  open the base branch's version, Copy Side-by-Side Image, Mark as Viewed, Copy Path, and **Discard
  Change…**, which undoes a working-tree change after asking: an uncommitted change is restored from `HEAD`,
  a new file that was never committed is deleted. Committed changes aren't touched; revert those with git.
- **N / M** with arrows — previous and next change (⌥⌘↑ / ⌥⌘↓ work from anywhere).

## Reverting a change

**Revert to develop…** (in a change's ··· menu or its right-click menu) puts a snapshot back the way the base
branch has it, whatever kind of change it is:

| Kind | Revert |
|---|---|
| Committed or Uncommitted | the base branch's image is written back |
| New | the file is removed |
| Deleted | the file comes back from the base branch |

**Revert All Shown to develop…** in the kinds menu does it for everything the list shows, so filter first (a
suite, `dark`, only *New*) to revert a set. Both ask first.

Only the working tree changes: nothing is staged or committed, so the reverted snapshots show up as changes of
their own until you commit them. That's the difference to **Discard Change…**, which only undoes
*uncommitted* edits, back to your last commit.

The info row says where the change comes from: the commit that last changed it on this branch (*Changed Oct 16
by Sample in a1b2c3d "Rename the badge"*), or *Not committed yet · compared with develop*. **Show in Library**
jumps to the snapshot in the library.

## Viewed marks

Viewed marks work like a code review's:

- They are stored per clone in `.git/snapshotkit/viewed.json` and never committed.
- A mark remembers the file's content. If the snapshot is re-recorded after you marked it, it shows as
  unviewed again.
- The footer shows your progress (*3/16 viewed*) as a bar.
- **Hide Viewed** in the kinds menu leaves only what's left to review.

## Re-records with no visible change

Re-recording on your machine often rewrites PNGs that look exactly the same — a different GPU or OS version
renders a few colours a tiny bit differently. Those uncommitted changes are noise in a pull request.

When there are any, a row at the top of the list says so (*1 uncommitted snapshot has no visible change*) and
offers **Discard…**. Discarding restores those files from `HEAD` (`git restore --staged --worktree`), after
asking. Only *uncommitted* changes whose difference is invisible (largest ΔE below 2.3) or identical are
discarded; anything visible stays. Rows with an invisible difference carry an **Invisible** label.

## Sharing a change

- **Copy Side-by-Side Image** (···) puts one image with before, after and the difference on the clipboard, for
  a pull request comment or a ticket.
- **Drag** rows out of the list to drop the images elsewhere.
- **Space** opens the selected image in Quick Look; **⌘C** copies it.

## From the command line

```bash
snapkit changes                       # vs the detected base branch, at the merge-base
snapkit changes --base main --tip     # vs main's current tip
snapkit changes --filter dark         # only paths containing "dark"
```

See [the CLI reference](cli.md#changes).
