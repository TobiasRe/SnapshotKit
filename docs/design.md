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
- **Linear's 2024 redesign:** reduce visual noise and keep things aligned. The chrome around the content (the
  "inverted L") is quiet and consistent; labels, icons and buttons line up across panes, which you feel more
  than see. Colour is mostly neutral and comes from a few inputs, not dozens of hand-picked values; status
  is a small coloured dot on a neutral label. A detail view says where you are in the list ("12 / 40") and
  steps through it in place.
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
2. **Glass for controls, never for content.** Controls that float over images (compare mode, zoom, captions,
   the slider knob) and the controls in pane headers are Liquid Glass, as Linear rings its toolbar icons:
   icon actions are glass circles (`GlassIconButton`, `GlassIconMenu`), an action with variations is a
   glass pill with a chevron (`GlassSplitButton`), and text controls are glass capsules (`quietControl()`).
   Lists, forms, logs and images stay solid. Neighbouring floating glass is grouped with `GlassGroup`.
3. **One tint.** The accent colour marks the single primary action in a region (`primaryActionStyle()`,
   which is `.glassProminent` on macOS 26). Neighbouring actions use `secondaryActionStyle()` (`.glass`).
4. **Colour means status, nothing else.** Green passed, red failed, orange flaky, magenta changed pixels.
   Change kinds use blue (committed), orange (uncommitted), green (new) and red (deleted).
   Status colour as *text* goes through `DS.Status.text(_:)`: system colours are tuned for fills and icons, and
   orange or green text on its own tint drops to about 2:1 in light mode. Never rely on colour alone: the
   history strip uses shape too when Differentiate Without Color is on.
5. **Titles carry the row.** Row and sidebar titles are medium weight; everything else in a row is
   secondary.
6. **Identifiers are code.** Paths, commands, suite identifiers and logs use SF Mono. Everything
   people read uses SF Pro text styles.
7. **Calm motion.** 150 ms ease-out (`DS.motion`), no springs and no bounces.
8. **Say it once, then offer the next step.** An empty list explains itself; the pane beside it stays blank
   rather than repeating it, and offers the one action that helps (Run Tests to record the first
   snapshots). The outcome of a run floats as a notice over the image area, with the next step as a
   button (Review Changes, Show Failures); information fades, errors stay until closed. Zero counts and
   footers of zeros are left out.
9. **Always current.** Snapshot files are watched, so a re-record from Xcode or the CLI shows up without
   a refresh; commits and branch switches are picked up when the app becomes active.

## Tokens

| Token | Values |
|---|---|
| Spacing (`DS.Space`) | 2 · 4 · 8 · 12 · 16 · 24 (4-pt grid) |
| Bars (`DS.Bar`) | header 52 · filters 36 · footer 32: every column's bars, so edges line up across panes |
| Radius (`DS.Radius`) | 6 thumbnails/chips · 10 panels · 16 floating bars (concentric with the window) |
| Surfaces (`DS.Surface`) | content · selection (primary 8%) · hairline (separator) |
| Type (`DS.Font`) | title (title3 semibold) · heading (headline) · body · secondary (callout) · caption · code (mono caption) · log (mono 11) · count (monospaced digits) |
| Status (`DS.Status`) | passed · failed · flaky · neutral · changed |

## Components

- `floatingGlass(in:)` / `floatingGlassCapsule()`: Liquid Glass on macOS 26 or later, `.regularMaterial` with
  a hairline and a soft shadow before that.
- `GlassGroup`: a `GlassEffectContainer` on macOS 26 or later, a plain stack before.
- `primaryActionStyle()` / `secondaryActionStyle()`: button roles, not looks.
- `panel()`: a solid content panel with a hairline border. Never glass.
- `PaneBar` / `PaneFooter`: the fixed-height bars of a column. A list has a header (search and view options),
  a filter bar and a footer (counts and the bulk action); a detail has a header (`DetailHeader`) and an info
  row (`DetailInfoRow`) of the same heights, so the hairlines under them continue across the window, and the
  list footers sit level with the sidebar's footer.
- `ListDetailSplit`: the list beside its detail (400 points by default, 280–520), with one divider position
  for every tab, kept across launches; dragging it on one tab sets it everywhere, and switching tabs never moves it. Content too wide
  for the column gives way (a long branch name truncates) instead of spilling over.
- `PropertySection` / `PropertyRow`: an inspector's properties (the Run tab's configuration): small section
  headers, grey labels in a 104-point column, values beside them, and where a value came from in quieter
  type under it.
- `PositionStepper`: "12 / 40" with previous and next in every detail header (⌥⌘↑ / ⌥⌘↓).
- `ListSectionHeader`: a group's name with its count in tertiary type. Lists have no row separators; the
  selection and the section headers carry the structure.
- `selectableRow(_:)`: a row under the pointer gets `DS.Surface.hover` (4%); a selected list row is
  `DS.Surface.selection` (the text colour at 8%), not the
  system's grey or accent block; the list keeps its selection, keyboard navigation and accessibility. The
  sidebar keeps the system selection, which on its material is already as quiet.
- `DS.Surface.content`: each column is one surface. Its bars, list and footer share it; only hairlines divide.
- `glassChrome(_:)`, `GlassIconButton`, `GlassIconMenu`, `GlassSplitButton`, `quietControl()`: the header
  controls, 28 points tall (`DS.Control`). Interactive Liquid Glass on macOS 26 and later; a faint fill with a
  hairline before that, with Increase Contrast, and in off-screen renders. Icon-only controls name
  themselves in the tooltip and to VoiceOver.
- The ⌘K palette (`QuickSwitcherView`, `PaletteCommand`): projects and the commands available right now in one
  ranked list, one line each, a command's shortcut where a project shows its folder, so the palette also
  teaches the keyboard.
- `ProjectMonogram`: a project's initials in a small neutral tile, telling projects apart without colour.
- `Chip`: a small status label: a coloured dot and neutral text in a hairline capsule, so several labels in a
  row stay calm and the text is readable in either appearance.
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
- Don't let a bar's height depend on its content: use `DS.Bar`, so neighbouring panes stay aligned.
- Don't let a control give way to a title: buttons keep their size (`fixedSize`) and titles truncate.
- Don't show the same empty state twice, or a count of zero.
- Don't add new spacing or radius values. If one seems necessary, add it here first.
