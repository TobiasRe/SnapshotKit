import AppKit
import SnapshotKitCore
import SwiftUI

/// SnapshotKit's tiny design system. See docs/design.md for the rationale.
///
/// Rule of thumb: system chrome (toolbar, sidebar) is Liquid Glass by itself; content is solid;
/// the only custom glass is controls that float over images. One tint — the accent — marks the
/// primary action; everything else that has color is status.
enum DS {
    /// 4-pt grid.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Concentric radii: thumbnails and chips sit inside panels, panels inside the window.
    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 16
    }

    /// Fixed heights for the bars at the top and bottom of every column, so their edges line up
    /// across the list and the detail (and the sidebar footer) whatever each one holds.
    enum Bar {
        /// Title or search, with the pane's actions.
        static let header: CGFloat = 52
        /// Filters and view options under the header, or the detail's info row.
        static let filters: CGFloat = 36
        /// Counts and bulk actions under a list.
        static let footer: CGFloat = 32
    }

    enum Font {
        /// Pane titles ("1 failing test in the last run").
        static let title = SwiftUI.Font.title3.weight(.semibold)
        /// Row and detail titles.
        static let heading = SwiftUI.Font.headline
        static let body = SwiftUI.Font.body
        static let secondary = SwiftUI.Font.callout
        static let caption = SwiftUI.Font.caption
        /// Paths, identifiers, commands and log output.
        static let code = SwiftUI.Font.system(.caption, design: .monospaced)
        static let log = SwiftUI.Font.system(size: 11, design: .monospaced)
        static let count = SwiftUI.Font.body.monospacedDigit().weight(.medium)
    }

    /// Color only ever means status. Structure uses system label/separator colors.
    enum Status {
        static let passed = Color.green
        static let failed = Color.red
        static let flaky = Color.orange
        static let neutral = Color.secondary
        static let changed = Color(red: 0.92, green: 0.16, blue: 0.86) // matches the diff overlay

        /// A status colour dark enough to read as small text on its own tint: system colours are
        /// tuned for fills and icons, and orange or green text on a pale tint falls well below 4.5:1
        /// in light mode. Darker still with Increase Contrast; dark mode keeps the bright colour.
        static func text(_ color: Color) -> Color {
            let base = NSColor(color)
            return Color(nsColor: NSColor(name: nil) { appearance in
                let resolved = base.usingColorSpace(.sRGB) ?? base
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                       .accessibilityHighContrastDarkAqua])
                switch dark {
                case .darkAqua?, .accessibilityHighContrastDarkAqua?: return resolved
                case .accessibilityHighContrastAqua?: return resolved.blended(withFraction: 0.55, of: .black) ?? resolved
                default: return resolved.blended(withFraction: 0.4, of: .black) ?? resolved
                }
            })
        }

        static func color(for kind: SnapshotChangeKind) -> Color {
            switch kind {
            case .committed: .blue
            case .uncommitted: .orange
            case .new: .green
            case .deleted: .red
            }
        }
    }

    /// Off-screen renders (headless captures, snapshot tests) can't show Liquid Glass, which the
    /// window server composites; they get an opaque stand-in so controls stay legible.
    nonisolated(unsafe) static var solidSurfaces = ProcessInfo.processInfo.environment["SNAPSHOTKIT_SOLID_SURFACES"] == "1"

    static var hasLiquidGlass: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    /// Short and calm: 150 ms ease-out, no springs — and none at all with Reduce Motion on.
    static var motion: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15)
    }
}

// MARK: - Glass, with fallbacks for macOS 14–25

extension View {
    /// A control bar floating over content (compare toolbar, captions, slider knob).
    func floatingGlass<S: Shape>(in shape: S) -> some View {
        modifier(FloatingGlass(shape: shape))
    }

    @ViewBuilder
    fileprivate func floatingGlassBody<S: Shape>(in shape: S, increasedContrast: Bool) -> some View {
        if increasedContrast && (DS.solidSurfaces || !DS.hasLiquidGlass) {
            // Increase Contrast: an opaque surface with a visible edge instead of a hairline.
            self
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(shape.stroke(Color.primary.opacity(0.6), lineWidth: 1))
        } else if DS.solidSurfaces {
            self
                .background(shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.94)))
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }

    func floatingGlassCapsule() -> some View {
        floatingGlass(in: Capsule())
    }

    /// The one prominent action in a region.
    @ViewBuilder
    func primaryActionStyle() -> some View {
        if DS.solidSurfaces {
            self.buttonStyle(.borderedProminent)
        } else if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Secondary actions next to a primary one.
    @ViewBuilder
    func secondaryActionStyle() -> some View {
        if DS.solidSurfaces {
            self.buttonStyle(.bordered)
        } else if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Solid content panel (never glass): hairline border, medium radius.
    func panel() -> some View {
        self
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// Soft blur where scrolling content meets a header, as Calendar does under its toolbar.
    @ViewBuilder
    func softTopEdge() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

/// Reads the contrast setting for `floatingGlass` (Liquid Glass adapts by itself; the fallbacks don't).
private struct FloatingGlass<S: Shape>: ViewModifier {
    var shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.floatingGlassBody(in: shape, increasedContrast: contrast == .increased)
    }
}

/// Groups nearby glass elements so they render (and morph) as one material on macOS 26+.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = DS.Space.s
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Small status label ("Flaky", "3/5 runs failed"): a coloured dot and neutral text in a hairline
/// capsule. The dot carries the status, so the text stays readable in any appearance and a row
/// with several labels doesn't turn into a row of colours.
struct Chip: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.leading, DS.Space.s - 2)
        .padding(.trailing, DS.Space.s)
        .padding(.vertical, DS.Space.xxs)
        .lineLimit(1)
        .fixedSize()   // never wraps: the text next to it truncates instead
        .background(Capsule().fill(Color.primary.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A bar of fixed height at the top or bottom of a column (see `DS.Bar`).
struct PaneBar<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: DS.Space.s) { content }
            .padding(.horizontal, DS.Space.m)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
    }
}

/// A list's footer: what's shown, and what can be done with all of it.
struct PaneFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            PaneBar(height: DS.Bar.footer) { content }
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
                .controlSize(.small)
        }
    }
}

/// A list section header: the group's name, and its count in quieter type.
struct ListSectionHeader: View {
    var title: String
    var count: Int

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: DS.Space.s)
            Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
        }
        .font(DS.Font.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

/// "12 / 40" with previous and next, at the top of a detail: where you are in the list, and the
/// way through it without going back to the list.
struct PositionStepper: View {
    var position: Int
    var count: Int
    var step: (Int) -> Void

    var body: some View {
        HStack(spacing: DS.Space.xxs) {
            Text("\(position) / \(count)")
                .font(DS.Font.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.trailing, DS.Space.xs)
                .accessibilityLabel("\(position) of \(count)")
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(position <= 1)
                .help("Previous (⌥⌘↑)")
                .accessibilityLabel("Previous")
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .disabled(position >= count)
                .help("Next (⌥⌘↓)")
                .accessibilityLabel("Next")
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }
}

// MARK: - Selection, surfaces and quiet controls

extension DS {
    enum Surface {
        /// The one surface of a column: its bars and its list share it, so only hairlines divide them.
        static let content = Color(nsColor: .controlBackgroundColor)
        /// A selected row: a whisper of the text colour, the same in every list and both appearances,
        /// instead of the system's solid grey or accent block.
        static let selection = Color.primary.opacity(0.08)
        /// An opaque hairline, for edges drawn over something else.
        static let hairline = Color(nsColor: .separatorColor)
    }
}

extension View {
    /// Marks a list row as selected with `DS.Surface.selection`, and turns off the list's own
    /// highlight (the list keeps its selection, keyboard navigation and accessibility).
    func selectableRow(_ selected: Bool) -> some View {
        self
            .listRowBackground(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(selected ? DS.Surface.selection : .clear)
                    .padding(.horizontal, DS.Space.s + 2)
            )
            .background(NativeHighlightOff())
    }

    /// A control drawn without a bezel, in a hairline capsule: the header controls' one look.
    func quietControl() -> some View {
        self
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xxs + 1)
            .overlay(Capsule().strokeBorder(DS.Surface.hairline))
            .contentShape(Capsule())
    }
}

/// Finds the table behind a SwiftUI `List` and turns off its selection highlight, so rows can draw
/// `DS.Surface.selection` instead.
private struct NativeHighlightOff: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Probe)?.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // A row can join its table after it joins the window (sidebars do).
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            var view = superview
            while let current = view {
                if let table = current as? NSTableView {
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                    return
                }
                view = current.superview
            }
        }
    }
}
