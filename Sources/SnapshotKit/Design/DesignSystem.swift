import AppKit
import SnapshotKitCore
import SwiftUI

/// SnapshotKit's tiny design system. See docs/DESIGN.md for the rationale.
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

    /// Short and calm: 150 ms ease-out, no springs — and none at all with Reduce Motion on.
    static var motion: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15)
    }
}

// MARK: - Glass, with fallbacks for macOS 14–25

extension View {
    /// A control bar floating over content (compare toolbar, captions, slider knob).
    @ViewBuilder
    func floatingGlass<S: Shape>(in shape: S) -> some View {
        if DS.solidSurfaces {
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

/// Small status chip ("Flaky", "3/5 runs failed").
struct Chip: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, DS.Space.s - 2)
            .padding(.vertical, DS.Space.xxs)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }
}
