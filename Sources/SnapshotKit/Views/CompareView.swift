import AppKit
import SnapshotKitCore
import SwiftUI

enum CompareMode: String, CaseIterable, Identifiable {
    case sideBySide = "Side by Side"
    case slider = "Slider"
    case difference = "Difference"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .sideBySide: "rectangle.split.2x1"
        case .slider: "slider.horizontal.below.rectangle"
        case .difference: "plusminus"
        }
    }
}

/// Decoded images plus their pixel difference, computed off the main thread.
struct ComparePair {
    var before: NSImage?
    var after: NSImage?
    var diff: NSImage?
    var stats: ImageDiffResult?
    var pixelSize: CGSize

    static func make(before: Data?, after: Data?) -> ComparePair {
        let a = before.flatMap(PixelImage.init(data:))
        let b = after.flatMap(PixelImage.init(data:))
        func ns(_ p: PixelImage?) -> NSImage? {
            guard let p, let cg = p.cgImage else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: p.width, height: p.height))
        }
        var stats: ImageDiffResult?
        if let a, let b { stats = ImageDiff.compare(a, b) }
        let size = CGSize(width: max(a?.width ?? 0, b?.width ?? 0), height: max(a?.height ?? 0, b?.height ?? 0))
        return ComparePair(before: ns(a), after: ns(b), diff: ns(stats?.image), stats: stats, pixelSize: size)
    }
}

/// Decoded pairs keyed by the compare view's identity, so revisiting a snapshot is instant.
final class ComparePairCache {
    final class Box { let pair: ComparePair; init(_ pair: ComparePair) { self.pair = pair } }
    static let shared: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 40
        return cache
    }()

    static func store(_ pair: ComparePair, for identity: String) {
        shared.setObject(Box(pair), forKey: identity as NSString)
    }
}

struct CompareView: View {
    @EnvironmentObject private var app: AppModel
    /// Produces the (before, after) image bytes; called off the main thread.
    var load: @Sendable () -> (Data?, Data?)
    var beforeLabel: String
    var afterLabel: String
    var identity: String

    @AppStorage("compareMode") private var modeRaw = CompareMode.sideBySide.rawValue
    @State private var pair: ComparePair?
    @State private var split: CGFloat = 0.5

    init(load: @escaping @Sendable () -> (Data?, Data?), beforeLabel: String, afterLabel: String, identity: String) {
        self.load = load
        self.beforeLabel = beforeLabel
        self.afterLabel = afterLabel
        self.identity = identity
        _pair = State(initialValue: ComparePairCache.shared.object(forKey: identity as NSString)?.pair)
    }

    private var mode: CompareMode { CompareMode(rawValue: modeRaw) ?? .sideBySide }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let pair {
                    content(pair)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(CheckerboardBackground())

            controls
                .padding(.bottom, DS.Space.m)
        }
        .clipped()
        .task(id: identity) {
            if let cached = ComparePairCache.shared.object(forKey: identity as NSString) {
                pair = cached.pair
                return
            }
            pair = nil
            let load = load, identity = identity
            let computed = await Task.detached {
                let (before, after) = load()
                return ComparePair.make(before: before, after: after)
            }.value
            ComparePairCache.store(computed, for: identity)
            pair = computed
        }
    }

    /// One floating glass bar over the canvas: mode, what changed, zoom.
    private var controls: some View {
        GlassGroup {
            HStack(spacing: DS.Space.m) {
                Picker("Mode", selection: $modeRaw) {
                    ForEach(CompareMode.allCases) { m in Text(m.rawValue).tag(m.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if let stats = pair?.stats {
                    HStack(spacing: DS.Space.xs + 1) {
                        Circle()
                            .fill(stats.isIdentical ? DS.Status.passed : DS.Status.changed)
                            .frame(width: 7, height: 7)
                        Text(stats.isIdentical
                             ? "Identical"
                             : String(format: "%.2f%% changed", stats.changedFraction * 100) + (stats.sizeChanged ? " · size differs" : ""))
                            .monospacedDigit()
                    }
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .help(stats.isIdentical ? "Pixel-identical" : "\(stats.changedPixels.formatted()) of \(stats.totalPixels.formatted()) pixels differ")
                }

                if let size = pair?.pixelSize, size.width > 0 {
                    Text("\(Int(size.width))×\(Int(size.height))")
                        .font(DS.Font.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                ControlGroup {
                    Button { withAnimation(DS.motion) { app.viewport.zoomOut() } } label: { Image(systemName: "minus") }
                        .help("Zoom out (⌘−)")
                    Menu {
                        Button("Fit") { withAnimation(DS.motion) { app.viewport.reset() } }
                        Divider()
                        ForEach([2, 4, 8, 16], id: \.self) { factor in
                            Button("\(factor)×") { withAnimation(DS.motion) { app.viewport = Viewport(scale: CGFloat(factor), offset: .zero) } }
                        }
                    } label: {
                        Text(zoomLabel).monospacedDigit().frame(minWidth: 34)
                    }
                    .help("Zoom relative to fit. ⌘0 or double-click fits.")
                    Button { withAnimation(DS.motion) { app.viewport.zoomIn() } } label: { Image(systemName: "plus") }
                        .help("Zoom in (⌘=)")
                }
                .controlGroupStyle(.navigation)
                .fixedSize()
            }
            .controlSize(.small)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s - 2)
            .floatingGlassCapsule()
        }
    }

    private var zoomLabel: String {
        let s = app.viewport.scale
        if abs(s - 1) < 0.01 { return "Fit" }
        return s >= 10 ? String(format: "%.0f×", s) : String(format: "%.1f×", s)
    }

    @ViewBuilder
    private func content(_ pair: ComparePair) -> some View {
        switch mode {
        case .sideBySide:
            HStack(spacing: 0) {
                pane(pair.before, label: beforeLabel, size: pair.pixelSize)
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                pane(pair.after, label: afterLabel, size: pair.pixelSize)
            }
        case .slider:
            GeometryReader { geo in
                let x = geo.size.width * split
                ZStack(alignment: .topLeading) {
                    ZoomableImage(image: pair.after, pixelSize: pair.pixelSize, viewport: app.viewport)
                    ZoomableImage(image: pair.before, pixelSize: pair.pixelSize, viewport: app.viewport)
                        .mask(alignment: .leading) { Rectangle().frame(width: x) }
                    ZoomPanSurface(viewport: $app.viewport)
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 1)
                        .shadow(color: .black.opacity(0.35), radius: 1)
                        .offset(x: x - 0.5)
                        .allowsHitTesting(false)
                    sliderKnob
                        .position(x: x, y: geo.size.height / 2)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            split = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                        })
                    caption(beforeLabel).padding(DS.Space.m)
                    caption(afterLabel).frame(maxWidth: .infinity, alignment: .trailing).padding(DS.Space.m)
                }
            }
        case .difference:
            pane(pair.diff ?? pair.after ?? pair.before,
                 label: pair.diff == nil ? "Only one side exists" : "Changed pixels",
                 size: pair.pixelSize)
        }
    }

    private var sliderKnob: some View {
        Image(systemName: "arrow.left.and.right")
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 30, height: 30)
            .floatingGlass(in: Circle())
            .contentShape(Circle())
            .help("Drag to compare")
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private func pane(_ image: NSImage?, label: String, size: CGSize) -> some View {
        ZoomableImage(image: image, pixelSize: size, viewport: app.viewport)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if image == nil {
                    ContentUnavailableView("No Image", systemImage: "photo", description: Text("This side doesn't exist."))
                }
            }
            .overlay(ZoomPanSurface(viewport: $app.viewport))
            .overlay(alignment: .topLeading) { caption(label).padding(DS.Space.m) }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs)
            .floatingGlassCapsule()
    }
}

/// Draws an image fitted to the available space, then applies the shared zoom and pan.
/// A Canvas keeps this out of layout (a GeometryReader + frame + position version caused layout cycles).
struct ZoomableImage: View {
    var image: NSImage?
    var pixelSize: CGSize
    var viewport: Viewport

    var body: some View {
        Canvas { context, canvasSize in
            guard let image else { return }
            let size = pixelSize.width > 0 ? pixelSize : image.size
            // Leave room for the floating controls at the bottom.
            let fit = Viewport.fitScale(image: size, in: CGSize(width: canvasSize.width - 48, height: canvasSize.height - 120))
            let scale = fit * viewport.scale
            let drawn = CGSize(width: size.width * scale, height: size.height * scale)
            let rect = CGRect(
                x: canvasSize.width / 2 + viewport.offset.width - drawn.width / 2,
                y: (canvasSize.height - 40) / 2 + viewport.offset.height - drawn.height / 2,
                width: drawn.width, height: drawn.height
            )
            // Nearest-neighbour when zoomed in so individual pixels stay crisp.
            context.draw(Image(nsImage: image).interpolation(scale >= 2 ? .none : .high), in: rect)
            // Hairline frame so the image edge is visible on any background.
            context.stroke(Path(rect.insetBy(dx: -0.5, dy: -0.5)), with: .color(Color(nsColor: .separatorColor)), lineWidth: 1)
        }
    }
}

/// Transparent AppKit layer that turns trackpad and mouse input into viewport changes:
/// pinch to zoom (around the cursor), two-finger scroll or mouse drag to pan,
/// ⌘-scroll to zoom with a mouse wheel, double-click to reset.
struct ZoomPanSurface: NSViewRepresentable {
    @Binding var viewport: Viewport

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        let binding = $viewport
        view.onChange = { change in
            var v = binding.wrappedValue
            change(&v)
            binding.wrappedValue = v
        }
    }

    final class SurfaceView: NSView {
        var onChange: ((inout Viewport) -> Void) -> Void = { _ in }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        /// Cursor position relative to the view center (the viewport's anchor space).
        private func anchor(for event: NSEvent) -> CGPoint {
            let p = convert(event.locationInWindow, from: nil)
            return CGPoint(x: p.x - bounds.midX, y: p.y - bounds.midY)
        }

        override func magnify(with event: NSEvent) {
            let a = anchor(for: event)
            onChange { $0.zoom(by: 1 + event.magnification, anchor: a) }
        }

        override func smartMagnify(with event: NSEvent) {
            let a = anchor(for: event)
            onChange { v in if v.scale > 1.01 { v.reset() } else { v.zoom(by: 2, anchor: a) } }
        }

        override func scrollWheel(with event: NSEvent) {
            if event.modifierFlags.contains(.command) {
                let a = anchor(for: event)
                let factor = exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
                onChange { $0.zoom(by: factor, anchor: a) }
            } else {
                let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                let delta = CGSize(width: event.scrollingDeltaX * multiplier, height: event.scrollingDeltaY * multiplier)
                onChange { $0.pan(by: delta) }
            }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onChange { $0.reset() }
            } else {
                NSCursor.closedHand.push()
            }
        }

        override func mouseDragged(with event: NSEvent) {
            let delta = CGSize(width: event.deltaX, height: event.deltaY)
            onChange { $0.pan(by: delta) }
        }

        override func mouseUp(with event: NSEvent) {
            if event.clickCount < 2 { NSCursor.pop() }
        }
    }
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 10
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .controlBackgroundColor)))
            let dark = Color.gray.opacity(0.08)
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : tile
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: tile, height: tile)), with: .color(dark))
                    x += tile * 2
                }
                y += tile
                row += 1
            }
        }
    }
}
