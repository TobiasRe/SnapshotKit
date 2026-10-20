# Keyboard shortcuts

## Projects and tabs

| Shortcut | Action |
|---|---|
| ⌘K | Go to a project or run a command (the palette) |
| ⌘O | Add a project |
| ⇧⌘O | Import a result bundle (`.xcresult`, e.g. a CI artifact) |
| ⌘, | Settings |
| ⌥⌘1 | Snapshots tab |
| ⌥⌘2 | Changes tab |
| ⌥⌘3 | Failures tab |
| ⌥⌘4 | Run tab |
| ⌘F | Filter the current list (Escape clears the filter, a second Escape leaves the field); the Failures list has no filter |

## Running and recording

| Shortcut | Action |
|---|---|
| ⌘R | Run the snapshot tests |
| ⌃⌘R | Run on the remote machine |
| ⇧⌘R | Re-record the selected test (snapshot, change or failure), then verify |
| ⌥⇧⌘R | Re-record the failing suites of the last run, then verify |
| ⌥⌘R | Check flakiness of the failing tests |
| ⌘. | Cancel the run |
| ⌥⌘O | Open the selected snapshot’s test in Xcode, at its function |

## Lists

| Shortcut | Action |
|---|---|
| ↑ / ↓ | Previous / next item in the focused list (in the library’s grid, the arrow keys move the selection; ↑ / ↓ by a row) |
| Return | Open the selected tile large (library grid) |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next snapshot, change or failure, wherever the focus is |
| V (in the Changes list), ⌥⌘V | Toggle the selected change’s Viewed mark; marking it viewed goes to the next unviewed change |
| ⌘-click, ⇧-click | Select several failures (Failures list), to re-record or flakiness-check them together |
| Space | Quick Look the selected snapshot, change or failure’s image (while comparing in Toggle mode, it flips the images instead) |
| ⌘C | Copy the selected image (in Failures, the actual image of the attempt shown) |

## Comparing

| Shortcut | Action |
|---|---|
| ⌘1 | Side by side |
| ⌘2 | Slider |
| ⌘3 | Difference |
| ⌘4 | Toggle |
| Space | Flip between the images (in Toggle mode), from the list or the image |
| ← / → | Move the slider divider (in Slider mode), from the list or the image |
| Arrow keys | Look around a zoomed-in image (on the image; in Slider mode ← / → move the divider) |
| ⌘= / ⌘− | Zoom in / out |
| ⌘0 | Zoom to Fit (also: double-click the image) |
| ⇧⌘0 | Zoom to the changed pixels |

Trackpad: pinch to zoom, double-tap with two fingers to zoom in (again to fit), two-finger drag to pan. Mouse:
drag to pan, ⌘-scroll to zoom at the pointer.

## The palette (⌘K)

| Key | Action |
|---|---|
| type | filter projects and commands |
| ↑ / ↓ | move the highlight |
| Return | open the project or run the command |
| Escape | close |
