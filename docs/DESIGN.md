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
- **Practitioner guidance:**
  - Start from standard structure (`NavigationSplitView`, toolbars, inspectors).
  - Add custom glass only where a surface floats over content, and group neighbouring glass in one container.
  - Don't tint every surface or stack glass on glass.

## Principles

1. **Chrome is glass, content is solid.** Use the system toolbar and sidebar as they are. Lists, forms,
   logs and images sit on solid backgrounds.
2. **Glass only floats over images.** The compare controls (mode, zoom, captions, slider knob) are the only
   custom glass. They're grouped with `GlassGroup`, so they render and morph as one material.
3. **One tint.** The accent colour marks the single primary action in a region (`primaryActionStyle()`,
   which is `.glassProminent` on macOS 26). Neighbouring actions use `secondaryActionStyle()` (`.glass`).
4. **Colour means status, nothing else.** Green passed, red failed, orange flaky, magenta changed pixels.
   Change kinds use blue (committed), orange (uncommitted), green (new) and red (deleted).
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
- `Chip`: a small status label.
- `softTopEdge()`: a soft scroll-edge blur under headers.

## Don'ts

- Don't paint behind the sidebar or toolbar, and don't put glass inside lists or forms.
- Don't use more than one prominent button per region, and don't use decorative colour or gradients.
- Don't add new spacing or radius values. If one seems necessary, add it here first.
