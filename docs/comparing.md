# Comparing images

Every place SnapshotKit shows two images — a change against the base branch, a failure's reference and actual
image, a snapshot against another variant or an earlier commit, a pair opened with `snapkit open` — uses the
same compare view. This page explains its modes, zoom, the pixel readout and the diagnosis.

## Compare modes

Choose a mode in the floating bar at the bottom of the canvas, or with ⌘1–⌘4 (View menu › Compare). The choice
is remembered.

| Mode | Shortcut | What you see | Best for |
|---|---|---|---|
| **Side by Side** | ⌘1 | before and after next to each other, zoomed and panned together | layout changes, copy changes |
| **Slider** | ⌘2 | one image over the other, split where you drag the knob (← / → move it) | the exact place a change starts |
| **Difference** | ⌘3 | only the changed pixels, in magenta, over a faded grey copy | small changes you can't spot |
| **Toggle** | ⌘4 | one image at a time; Space flips | movement and shifts, which are easier to see than to compare |

Each side is labelled: *Reference* and *Actual* for failures, the base branch and *This branch* / *Working
tree* for changes, the variant or commit for library comparisons.

In a narrow window the bar drops the size and statistics first, then shows icons instead of mode names,
rather than wrapping.

## Zoom and pan

| Action | How |
|---|---|
| Zoom in / out | ⌘= / ⌘−, pinch, or the **−** / **+** buttons |
| Pick a level | click the level (*Fit*, *2.0×*…) for Fit, 2×, 4×, 8×, 16× |
| Fit | ⌘0, or double-click the image |
| Pan | drag with the mouse or two fingers |
| Zoom to the change | ⇧⌘0, or the ⌖ button: frames the changed pixels |

Levels are relative to *Fit*, so 2× is twice the size that fits the pane. Both sides always share one zoom and
position. Zooming keeps the point you were looking at in place.

**Zoom to Change** matters for large screenshots where a two-pixel change is invisible at Fit: it zooms in on
the bounding box of every changed pixel.

## Pixel readout

Hover the image to read the pixel under the pointer. The readout shows its coordinates, the colour on each
side and their **ΔE** — the CIE94 colour difference that swift-snapshot-testing's `perceptualPrecision`
is based on. Below about 2.3, nobody can see the difference.

## Statistics

The bar shows, for the pair:

- a coloured dot and **N% changed** — the share of pixels that differ at all,
- the pixel size (`1,020×330`), or both sizes when they differ (`360×240 → 360×280`).

## The diagnosis

When a difference isn't obvious, a note above the bar says what kind it is. SnapshotKit measures every pixel's
ΔE and classifies the pair, in this order:

| Diagnosis | When | What it says | What it offers |
|---|---|---|---|
| Identical | no pixel differs and the size is the same | *The images are pixel-identical.* | |
| Size changed | width or height differ | *The image size changed, so the device, scale or layout differs from the reference.* | |
| **Invisible** | pixels differ, but none by ΔE 2.3 or more | *No visible difference (largest ΔE 0.5), typical of rendering on another machine or OS version.* | the `perceptualPrecision` that would pass |
| **Few pixels** | fewer than 0.1% of pixels differ visibly | *3 visible pixels changed in a 4×2 px area: often anti-aliasing, a caret or a timestamp.* | the `precision` that would pass |
| Visible | anything else | *Visible change in a 105×58 area at 847, 136.* | |

Visible changes speak for themselves, so the note only appears for *Invisible*, *Few pixels* and *Size
changed*.

The suggested value is rounded down so that it really passes:

- *Invisible*: `perceptualPrecision = 1 − largest ΔE / 100`, to two decimals (largest ΔE 0.5 → `0.99`),
- *Few pixels*: `precision = 1 − changed pixels / all pixels`, to four decimals.

**Copy** puts `perceptualPrecision: 0.99` (or `precision: …`) on the clipboard, ready to paste into
`.image(precision:perceptualPrecision:)`. Prefer fixing the cause when you can: an *Invisible* failure usually
means the reference was recorded on a different machine, GPU or OS version than the one comparing it. Record
where CI runs (see [remote runs](remote-runs.md)) rather than loosening every test.

## The same view everywhere

| Where | Before | After |
|---|---|---|
| Changes tab | the base branch (merge-base or tip) | this branch or the working tree |
| Failures tab | the reference | the image the test produced |
| Library › Compare with… | another variant or an earlier commit | the selected snapshot |
| A pair opened from outside ([diff tool](diff-tool.md)) | the reference | the actual image |
