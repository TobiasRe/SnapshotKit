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

    enum Pane {
        /// A detail beside its list never gets narrower than this; the list gives way first.
        static let minDetailWidth: CGFloat = 440
    }

    /// Header controls: icon buttons are circles of this size, text controls capsules of this height.
    enum Control {
        static let height: CGFloat = 28
        static let icon: CGFloat = 13
    }

    enum Font {
        /// Row and detail titles.
        static let heading = SwiftUI.Font.headline
        static let secondary = SwiftUI.Font.callout
        static let caption = SwiftUI.Font.caption
        /// Paths, identifiers, commands and log output.
        static let code = SwiftUI.Font.system(.caption, design: .monospaced)
        static let log = SwiftUI.Font.system(size: 11, design: .monospaced)
    }

    /// Color only ever means status. Structure uses system label/separator colors.
    enum Status {
        /// The dot beside a status label.
        static let dot: CGFloat = 6
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
        floatingGlass(in: Capsule(style: .circular))
    }

    /// The one prominent action in a region: an accent capsule as tall as the controls beside it
    /// (the system's prominent styles are shorter and keep rounded corners on the Mac).
    func primaryActionStyle() -> some View {
        buttonStyle(PrimaryActionButtonStyle())
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
            Circle().fill(color).frame(width: DS.Status.dot, height: DS.Status.dot)
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.leading, DS.Space.s - 2)
        .padding(.trailing, DS.Space.s)
        .padding(.vertical, DS.Space.xxs)
        .lineLimit(1)
        .fixedSize()   // never wraps: the text next to it truncates instead
        .background(Capsule(style: .circular).fill(Color.primary.opacity(0.04)))
        .overlay(Capsule(style: .circular).strokeBorder(Color(nsColor: .separatorColor)))
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
        /// A selected grid tile and palette row: a whisper of the text colour, the same in both
        /// appearances. Lists use the system highlight instead.
        /// Stronger with Increase Contrast, where a whisper would not be seen.
        static let selection = text(opacity: 0.08, increasedContrast: 0.2)
        /// The chosen segment of a segmented control: a little firmer than a selected row, since it
        /// sits on glass rather than on a plain column.
        static let thumb = text(opacity: 0.1, increasedContrast: 0.25)
        /// A filter match in the log: a soft tint, so the line's own color stays readable on it.
        static let match = Color.yellow.opacity(0.35)
        /// A row under the pointer: half the selection.
        static let hover = Color.primary.opacity(0.04)
        /// An opaque hairline, for edges drawn over something else.
        static let hairline = Color(nsColor: .separatorColor)

        /// The text colour at `opacity`, or at `increasedContrast` with Increase Contrast on.
        private static func text(opacity: CGFloat, increasedContrast: CGFloat) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let highContrast = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                                .accessibilityHighContrastDarkAqua])?.rawValue.contains("HighContrast") ?? false
                return NSColor.labelColor.withAlphaComponent(highContrast ? increasedContrast : opacity)
            })
        }
    }
}

extension View {
    /// Marks a list row under the pointer. Selection is the list's own system highlight, like
    /// every Mac app's: no custom fill, nothing reaching into the AppKit table underneath.
    func selectableRow(_ selected: Bool) -> some View {
        modifier(SelectableRow(selected: selected))
    }

    /// Selection and hover fills for something that isn't a list row (a grid tile), which has no
    /// system highlight of its own.
    func selectableTile(_ selected: Bool) -> some View {
        modifier(SelectableTile(selected: selected))
    }

    /// A control drawn without a bezel in a glass capsule: the look of every text control in the
    /// pane headers and filter bars (see `glassChrome`).
    func quietControl() -> some View {
        self
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .modifier(QuietControlText())
            .padding(.horizontal, DS.Space.s + 2)
            .frame(height: DS.Control.height)
            .glassChrome(Capsule(style: .circular))
            .contentShape(Capsule(style: .circular))
    }

    /// A text field in the same 28-point glass capsule as the controls beside it (search, base
    /// branch), instead of a square-cornered box. The height is fixed: a focused field (the field
    /// editor) is otherwise a point or two taller, and focus arrives at an unpredictable moment,
    /// which moved everything below.
    func fieldChrome() -> some View {
        self
            .frame(height: 16)
            .padding(.horizontal, DS.Space.m)
            .frame(height: DS.Control.height)
            .glassChrome(Capsule(style: .circular))
    }

    /// Liquid Glass around a header control, the way Linear rings its toolbar icons: interactive
    /// glass on macOS 26 and later; a whisper of fill and a hairline before that and in off-screen
    /// renders, where glass can't be composited.
    func glassChrome<S: InsettableShape>(_ shape: S) -> some View {
        modifier(GlassChrome(shape: shape))
    }
}

/// Accent-filled glass on macOS 26 and later; a solid accent capsule before that, in off-screen
/// renders and with Increase Contrast. White text either way.
struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .fontWeight(.medium)
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.7))
            .padding(.horizontal, DS.Space.m + 2)
            .frame(height: DS.Control.height)
            .contentShape(Capsule(style: .circular))
        let fill = Color.accentColor.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
        if DS.solidSurfaces || !DS.hasLiquidGlass || contrast == .increased {
            label.background(Capsule(style: .circular).fill(fill))
        } else if #available(macOS 26.0, *) {
            label.glassEffect(.regular.tint(fill).interactive(), in: Capsule(style: .circular))
        }
    }
}

/// Text like the icon buttons beside it, not accent-coloured link text; dimmed when disabled,
/// which a fixed colour would otherwise override.
struct QuietControlText: ViewModifier {
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content.foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.6))
    }
}

/// The row background under the pointer, so you see what a click will select.
private struct SelectableRow: ViewModifier {
    var selected: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            // The list draws the selection itself (the system highlight); this only marks the row
            // under the pointer, and never a selected one.
            .listRowBackground(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(hovering && !selected ? DS.Surface.hover : .clear)
                    .padding(.horizontal, DS.Space.s + 2)
            )
    }
}

private struct SelectableTile: ViewModifier {
    var selected: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .fill(selected ? DS.Surface.selection : hovering ? DS.Surface.hover : .clear))
            .onHover { hovering = $0 }
    }
}

/// "Module › Suite": where a snapshot lives, the way a detail header says it.
enum Breadcrumb {
    static func of(module: String?, suite: String) -> String {
        [module, suite].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " › ")
    }

    /// A test suite's identifier ("Bundle/Suite") read the same way.
    static func of(identifier: String) -> String {
        identifier.split(separator: "/").joined(separator: " › ")
    }
}

/// A list beside its detail, with one divider position shared by every tab and kept across
/// launches: switching tabs never moves the divider, and dragging it sets it everywhere.
struct ListDetailSplit<List: View, Detail: View>: View {
    @AppStorage("listColumnWidth") private var width = Self.idealWidth
    @State private var dragStart: Double?
    var minWidth: Double = 280
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail

    static var idealWidth: Double { 400 }
    static var maxWidth: Double { 520 }

    var body: some View {
        GeometryReader { geo in
            let shown = Self.clamp(width, min: minWidth, available: geo.size.width)
            HStack(spacing: 0) {
                // Leading and clipped: content wider than the column (a long branch name) is cut
                // at its end rather than spilling over both edges.
                list.frame(width: shown, alignment: .leading).clipped()
                Divider()
                    .overlay {
                        // A wider grab area than the hairline, with the resize cursor.
                        Color.clear
                            .frame(width: 9)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    let start = dragStart ?? shown
                                    dragStart = start
                                    width = Self.clamp(start + value.translation.width, min: minWidth, available: geo.size.width)
                                }
                                .onEnded { _ in dragStart = nil })
                            .accessibilityHidden(true)
                    }
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    static func clamp(_ width: Double, min minWidth: Double, available: Double) -> Double {
        let upper = Swift.max(minWidth, Swift.min(maxWidth, available - DS.Pane.minDetailWidth))
        return Swift.min(Swift.max(width, minWidth), upper)
    }
}

private struct GlassChrome<S: InsettableShape>: ViewModifier {
    var shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if DS.solidSurfaces || !DS.hasLiquidGlass || contrast == .increased {
            content
                .background(shape.fill(Color.primary.opacity(0.04)))
                .overlay(shape.strokeBorder(DS.Surface.hairline))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        }
    }
}

/// An icon-only header button in a glass circle; its name is the tooltip and the accessibility label.
struct GlassIconButton: View {
    var title: String
    var symbol: String
    /// The tooltip, when it should say more than the name.
    var help: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: DS.Control.icon, weight: .medium))
                .frame(width: DS.Control.height, height: DS.Control.height)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(QuietControlText())
        .glassChrome(Circle())
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

/// An icon-only header menu in a glass circle ("···", sort).
struct GlassIconMenu<Content: View>: View {
    var title: String
    var symbol: String
    var help: String?
    @ViewBuilder var content: Content

    var body: some View {
        // A titled label, shown as its icon: the title is the menu's own name for VoiceOver, which
        // otherwise reads the symbol ("More") whatever label is set on the glass around it.
        Menu { content } label: {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: DS.Control.height, height: DS.Control.height)
        .glassChrome(Circle())
        .contentShape(Circle())
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

/// An action with a menu of variations, as one glass pill: the icon does the common thing, the
/// chevron offers the rest (Re-record: this test, or its whole suite).
struct GlassSplitButton<Content: View>: View {
    var title: String
    var symbol: String
    var help: String?
    var action: () -> Void
    @ViewBuilder var menu: Content

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: DS.Control.icon, weight: .medium))
                    .frame(width: DS.Control.height + 4, height: DS.Control.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Primary, like the menus beside it (a native menu label can't be tinted secondary).
            .modifier(QuietControlText())
            .help(help ?? title)
            .accessibilityLabel(title)
            Rectangle()
                .fill(DS.Surface.hairline)
                .frame(width: 1, height: DS.Control.height - 12)
                .accessibilityHidden(true)
            // Titled like GlassIconMenu, or VoiceOver reads the chevron's name ("Down").
            Menu { menu } label: {
                Label("\(title) Options", systemImage: "chevron.down").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: DS.Control.height - 2, height: DS.Control.height)
            .help("More ways to \(title.lowercased())")
        }
        .glassChrome(Capsule(style: .circular))
    }
}

/// A project's failing tests, wherever projects are listed (sidebar, menu bar): the failed dot
/// and the number, read as "3 failing".
struct FailingCount: View {
    var count: Int

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Circle().fill(DS.Status.failed).frame(width: DS.Status.dot, height: DS.Status.dot)
            Text("\(count)").monospacedDigit()
        }
        .font(DS.Font.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) failing")
    }
}

/// A sentence with a status icon: the icon carries the color, the text stays readable in either
/// appearance (whole red or orange sentences glare in dark mode). Icons share one width, so the
/// text of stacked notes starts at the same edge.
struct StatusNote: View {
    var text: String
    var symbol: String
    var color: Color

    init(_ text: String, symbol: String, color: Color) {
        self.text = text
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            Text(Self.code(text))
        } icon: {
            Image(systemName: symbol).foregroundStyle(color).frame(width: DS.Space.l)
        }
    }

    /// Messages name commands in backticks ("Run `xcodes install 16.2`"); those parts are set in
    /// code type. Only backticks: full Markdown would turn `__Snapshots__` in a path bold.
    static func code(_ text: String) -> AttributedString {
        let parts = text.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.count % 2 == 1 else { return AttributedString(text) }
        var result = AttributedString()
        for (index, part) in parts.enumerated() {
            var piece = AttributedString(String(part))
            if index % 2 == 1 { piece.font = DS.Font.code }
            result += piece
        }
        return result
    }
}

/// One choice of a `GlassSegmented`: a title, or an icon with the title as its tooltip.
struct Segment<Value: Hashable> {
    var value: Value
    var title: String
    var symbol: String?
    var help: String?

    init(_ title: String, symbol: String? = nil, help: String? = nil, value: Value) {
        self.title = title
        self.symbol = symbol
        self.help = help
        self.value = value
    }
}

/// A segmented control as a glass pill, like the buttons beside it: the chosen segment is a quiet
/// capsule that slides over, instead of the system's grey track with a white block.
struct GlassSegmented<Value: Hashable>: View {
    var title: String
    var segments: [Segment<Value>]
    @Binding var selection: Value
    /// Off when the control already sits on glass (the compare bar), which needs no second pill.
    var chrome = true
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments.indices, id: \.self) { index in
                segment(segments[index])
            }
        }
        .padding(DS.Space.xxs)
        .modifier(SegmentedChrome(enabled: chrome))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func segment(_ segment: Segment<Value>) -> some View {
        let selected = segment.value == selection
        return Button {
            withAnimation(DS.motion) { selection = segment.value }
        } label: {
            Group {
                if let symbol = segment.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: DS.Control.icon, weight: .medium))
                        .frame(width: DS.Control.height + 4)
                } else {
                    Text(segment.title)
                        .lineLimit(1)
                        .padding(.horizontal, DS.Space.s + 2)
                }
            }
            .frame(height: DS.Control.height - 2 * DS.Space.xxs)
            .foregroundStyle(Color(nsColor: selected ? .labelColor : .secondaryLabelColor))
            .background {
                if selected {
                    Capsule(style: .circular)
                        .fill(DS.Surface.thumb)
                        .matchedGeometryEffect(id: "thumb", in: thumb)
                }
            }
            .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(.plain)
        .help(segment.help ?? segment.title)
        .accessibilityLabel(segment.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SegmentedChrome: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.glassChrome(Capsule(style: .circular)) } else { content }
    }
}
