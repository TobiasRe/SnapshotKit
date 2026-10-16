# SnapshotKit design system

A deliberately tiny system for a native macOS tool. It follows the Liquid Glass design language
(macOS 26 and later) and falls back gracefully on macOS 14–25. Tokens and helpers live in
[`Sources/SnapshotKit/Design/DesignSystem.swift`](../Sources/SnapshotKit/Design/DesignSystem.swift).

## Where the inspiration comes from

- **Finder and System Settings:** the sidebar is the system's glass material, never painted over. The
  layering stays quiet and consistent across every pane.
- **Safari and OpenMark:** the toolbar floats above the document and recedes when you don't need it.
- **Photos and Preview:** editing and zoom controls float as glass over the image, not in a strip above it.
- **Calendar:** headers softly blur the content scrolling beneath them.
- **Kaleidoscope and other image-diff tools:** comparing images needs more than side by side. A one-up *toggle*
  shows movement, a loupe reads exact pixels, and the tool should take you to the change rather than make you
  hunt for it.
- **Code review (GitHub's *Viewed* checkbox):** reviewing many changed files is a checklist. Mark one, move on.
- **WWDC26 refinements:** Liquid Glass now diffuses busy backgrounds better. Standard components pick up these
  changes for free; custom controls don't, and have to be checked with Increase Contrast, Reduce Transparency
  and Reduce Motion. That is one more reason to keep custom glass to a minimum.
- **Practitioner guidance:**
  - Start from standard structure (`NavigationSplitView`, toolbars, inspectors).
  - Add custom glass only where a surface floats over content, and group neighbouring glass in one container.
  - Don't tint every surface or stack glass on glass.

## What the app is for

SnapshotKit is for **inspecting, managing and updating snapshots**; failing and flaky tests are one part of
that. The structure follows: the library (every snapshot) is the first tab and the home of a project, Changes
and Failures are focused views of the same snapshots, and Run is where tests run and record. Every snapshot
can be followed between these views, and re-recording is available wherever a snapshot is shown.

## Principles

1. **Chrome is glass, content is solid.** Use the system toolbar and sidebar as they are. Lists, forms,
   logs and images sit on solid backgrounds.
2. **Glass only floats over images.** The compare controls (mode, zoom, captions, slider knob) are the only
   custom glass. They're grouped with `GlassGroup`, so they render and morph as one material.
3. **One tint.** The accent colour marks the single primary action in a region (`primaryActionStyle()`,
   which is `.glassProminent` on macOS 26). Neighbouring actions use `secondaryActionStyle()` (`.glass`).
4. **Colour means status, nothing else.** Green passed, red failed, orange flaky, magenta changed pixels.
   Change kinds use blue (committed), orange (uncommitted), green (new) and red (deleted).
   Status colour as *text* goes through `DS.Status.text(_:)`: system colours are tuned for fills and icons, and
   orange or green text on its own tint drops to about 2:1 in light mode. Never rely on colour alone: the
   history strip uses shape too when Differentiate Without Color is on.
5. **Identifiers are code.** Paths, commands, suite identifiers and logs use SF Mono. Everything
   people read uses SF Pro text styles.
6. **Calm motion.** 150 ms ease-out (`DS.motion`), no springs and no bounces.

## Tokens

| Token | Values |
|---|---|
| Spacing (`DS.Space`) | 2 · 4 · 8 · 12 · 16 · 24 (4-pt grid) |
| Radius (`DS.Radius`) | 6 thumbnails/chips · 10 panels · 16 floating bars (concentric with the window) |
| Type (`DS.Font`) | title (title3 semibold) · heading (headline) · body · secondary (callout) · caption · code (mono caption) · log (mono 11) · count (monospaced digits) |
| Status (`DS.Status`) | passed · failed · flaky · neutral · changed |

## Components

- `floatingGlass(in:)` / `floatingGlassCapsule()`: Liquid Glass on macOS 26 or later, `.regularMaterial` with
  a hairline and a soft shadow before that.
- `GlassGroup`: a `GlassEffectContainer` on macOS 26 or later, a plain stack before.
- `primaryActionStyle()` / `secondaryActionStyle()`: button roles, not looks.
- `panel()`: a solid content panel with a hairline border. Never glass.
- `Chip`: a small status label (readable text colour built in).
- `HistoryStrip`: the signature element. One mark per recent run of a test, green, red or orange. A flaky test
  reads as a broken pattern, a regression as a clean switch to red. It appears in failure rows (compact) and
  the failure detail (regular).
- `DiagnosisNote` / `DiagnosisChip`: say what kind of difference it is when it isn't plainly visible
  (Invisible, Few pixels, Size changed), and offer the precision that would pass.
- `PixelReadout`: the hover loupe, showing coordinates, both colours and their ΔE.
- `SnapshotRow` / grid tile: thumbnail, test name, variant in code type, state chip (New, Modified, Orphaned)
  and `StatusMarks` at the trailing edge (failing ✕, flaky ⚠, change dot). One row design for every list.
- `SnapshotViewer`: a single image with the compare view's zoom, pan and readout; the compare view itself
  is reused for versions and variants, so every comparison looks and behaves the same.
- `MenuBarLabel` / `ProgressPie` / `MenuBarPanel`: the optional menu bar item. The icon is a 16 pt template
  image (a ring with a pie), so it follows the menu bar's colour; the panel reuses the row and chip styles.
- Scope controls degrade instead of clipping: segmented with counts, then without, then a menu
  (`ViewThatFits`).
- `softTopEdge()`: a soft scroll-edge blur under headers.

## Enforcement

- **Every view uses the tokens.** The only literal left is one layout offset.
- **Snapshot tests** (`Tests/SnapshotKitAppTests`) render every pane, state and compare mode in light and
  dark at a 99.9% pixel tolerance, so visual changes have to be re-recorded on purpose.
  Off-screen rendering can't composite Liquid Glass, so `DS.solidSurfaces` draws an opaque stand-in there
  (headless captures included). Real glass needs a look on screen.
- **An accessibility audit test** walks each tab's live accessibility tree and fails on unlabeled controls.
- **Re-record only what you changed.** In a record-mode run of the whole suite, layout can depend on which
  tests failed earlier in that run. Re-record single tests with `--filter`, then run everything normally.

## Don'ts

- Don't paint behind the sidebar or toolbar, and don't put glass inside lists or forms.
- Don't use more than one prominent button per region, and don't use decorative colour or gradients.
- Don't add new spacing or radius values. If one seems necessary, add it here first.
