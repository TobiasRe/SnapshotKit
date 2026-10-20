import AppKit
import SnapshotKitCore
import SwiftUI

enum CompareMode: String, CaseIterable, Identifiable {
    case sideBySide = "Side by Side"
    case slider = "Slider"
    case difference = "Difference"
    /// One image at a time; Space flips. Movement is easier to see than side by side.
    case toggle = "Toggle"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .sideBySide: "rectangle.split.2x1"
        case .slider: "slider.horizontal.below.rectangle"
        case .difference: "plusminus"
        case .toggle: "square.on.square"
        }
    }
}

/// Decoded images plus their pixel difference, computed off the main thread.
struct ComparePair {
    var before: NSImage?
    var after: NSImage?
    var diff: NSImage?
    var stats: ImageDiffResult?
    var diagnosis: DiffDiagnosis?
    var pixelSize: CGSize
    /// Raw pixels for the hover readout.
    var beforePixels: PixelImage?
    var afterPixels: PixelImage?

    /// Approximate memory: raw pixels of both sides, the diff, and the decoded images.
    var byteCost: Int {
        let pixels = Int(pixelSize.width * pixelSize.height) * 4
        return pixels * 5
    }

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
        return ComparePair(before: ns(a), after: ns(b), diff: ns(stats?.image), stats: stats,
                           diagnosis: stats.map(DiffDiagnosis.init), pixelSize: size, beforePixels: a, afterPixels: b)
    }
}

/// Decoded pairs keyed by the compare view's identity, so revisiting a snapshot is instant.
enum ComparePairCache {
    final class Box { let pair: ComparePair; init(_ pair: ComparePair) { self.pair = pair } }
    /// Full-screen @3x pairs hold tens of megabytes of pixels each, so the cache is bounded by
    /// size, not only by count.
    /// NSCache is thread-safe (decoding fills it off the main thread).
    nonisolated(unsafe) static let shared: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 40
        cache.totalCostLimit = 400 * 1024 * 1024
        return cache
    }()

    static func store(_ pair: ComparePair, for identity: String) {
        shared.setObject(Box(pair), forKey: identity as NSString, cost: pair.byteCost)
    }
}

struct CompareView: View {
    @Environment(AppModel.self) private var app
    /// Produces the (before, after) image bytes; called off the main thread.
    var load: @Sendable () -> (Data?, Data?)
    var beforeLabel: String
    var afterLabel: String
    var identity: String

    @AppStorage("compareMode") private var modeRaw = CompareMode.sideBySide.rawValue
    @State private var pair: ComparePair?
    @State private var split: CGFloat = 0.5
    /// Toggle mode: whether the actual (after) image is showing.
    @State private var showingAfter = true
    @State private var canvasSize: CGSize = .zero
    /// The image pixel under the pointer, for the readout.
    @State private var probe: PixelProbe?

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
            .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }

            VStack(spacing: DS.Space.s) {
                if let probe, let pair {
                    PixelReadout(probe: probe, before: pair.beforePixels, after: pair.afterPixels,
                                 beforeLabel: beforeLabel, afterLabel: afterLabel)
                } else if let diagnosis = pair?.diagnosis {
                    DiagnosisNote(diagnosis: diagnosis)
                }
                controls
            }
            .padding(.bottom, DS.Space.m)
        }
        .clipped()
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudgeSplit(-1) }
        .onKeyPress(.rightArrow) { nudgeSplit(1) }
        .onKeyPress(.space) {
            guard mode == .toggle else { return .ignored }
            showingAfter.toggle()
            return .handled
        }
        .onChange(of: app.zoomToChangeRequest) { zoomToChange() }
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
    /// Drops the less important parts first when the pane is narrow instead of wrapping.
    private var controls: some View {
        GlassGroup {
            ViewThatFits(in: .horizontal) {
                controlBar(showStats: true, showSize: true)
                controlBar(showStats: true, showSize: false)
                controlBar(showStats: false, showSize: false)
                controlBar(showStats: false, showSize: false, iconsOnly: true)
            }
            .padding(.horizontal, DS.Space.m)
        }
    }

    private func controlBar(showStats: Bool, showSize: Bool, iconsOnly: Bool = false) -> some View {
        HStack(spacing: DS.Space.m) {
            // The bar is glass already, so the segments sit straight on it.
            GlassSegmented(title: "Compare Mode", segments: CompareMode.allCases.enumerated().map { index, m in
                Segment(m.rawValue, symbol: iconsOnly ? m.systemImage : nil, help: "\(m.rawValue) (⌘\(index + 1))", value: m.rawValue)
            }, selection: $modeRaw, chrome: false)
            .fixedSize()

            if showStats, let stats = pair?.stats {
                HStack(spacing: DS.Space.xs + 1) {
                    Circle()
                        .fill(stats.isIdentical ? DS.Status.passed : DS.Status.changed)
                        .frame(width: DS.Status.dot, height: DS.Status.dot)
                    Text(stats.isIdentical
                         ? "Identical"
                         : String(format: "%.2f%% changed", stats.changedFraction * 100))
                        .monospacedDigit()
                }
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help(stats.isIdentical ? "Pixel-identical" : "\(stats.changedPixels.formatted()) of \(stats.totalPixels.formatted()) pixels differ")
            }

            if showSize, let size = pair?.pixelSize, size.width > 0 {
                // When the sizes differ, both: that is the difference worth reading.
                if let a = pair?.beforePixels, let b = pair?.afterPixels, a.width != b.width || a.height != b.height {
                    Text("\(a.width)×\(a.height) → \(b.width)×\(b.height)")
                        .font(DS.Font.caption.monospacedDigit())
                        .foregroundStyle(DS.Status.text(DS.Status.changed))
                        .fixedSize()
                        .help("The image size changed: a different device, scale or layout")
                } else {
                    Text("\(Int(size.width))×\(Int(size.height))")
                        .font(DS.Font.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }

            if pair?.stats?.changedBounds != nil {
                Button { zoomToChange() } label: { Image(systemName: "scope") }
                    .buttonStyle(.borderless)
                    .help("Zoom to Change (⇧⌘0)")
                    .accessibilityLabel("Zoom to Change")
            }

            ZoomControls()
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s - 2)
        .floatingGlassCapsule()
        .fixedSize()
    }

    private func hover(_ location: (point: CGPoint, canvas: CGSize)?, pixelSize: CGSize) {
        guard let location, pixelSize.width > 0,
              let p = app.viewport.pixel(at: location.point, imageSize: pixelSize, canvas: location.canvas) else {
            if probe != nil { probe = nil }
            return
        }
        let next = PixelProbe(x: p.x, y: p.y)
        if next != probe { probe = next }
    }

    /// Frames the changed pixels, so a two-pixel difference in a full-screen snapshot is findable.
    private func zoomToChange() {
        guard let pair, let bounds = pair.stats?.changedBounds, canvasSize.width > 0 else { return }
        // Side by side shows each image in half the width.
        let pane = mode == .sideBySide ? CGSize(width: (canvasSize.width - 1) / 2, height: canvasSize.height) : canvasSize
        withAnimation(DS.motion) {
            app.viewport = .focusing(on: bounds, imageSize: pair.pixelSize, canvas: pane)
        }
    }

    /// ← / → move the slider divider by 5% in slider mode.
    private func nudgeSplit(_ direction: CGFloat) -> KeyPress.Result {
        guard mode == .slider else { return .ignored }
        withAnimation(DS.motion) { split = min(max(split + direction * 0.05, 0), 1) }
        return .handled
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
                    ZoomPanSurface(viewport: Bindable(app).viewport, onHover: { hover($0, pixelSize: pair.pixelSize) })
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
        case .toggle:
            pane(showingAfter ? pair.after : pair.before, label: showingAfter ? afterLabel : beforeLabel, size: pair.pixelSize)
                .overlay(alignment: .topTrailing) {
                    Button { showingAfter.toggle() } label: {
                        Label("Flip", systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)
                    .font(DS.Font.caption.weight(.medium))
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xs)
                    .floatingGlassCapsule()
                    .padding(DS.Space.m)
                    .help("Show the \(showingAfter ? beforeLabel : afterLabel) image (Space)")
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
            .accessibilityElement()
            .accessibilityLabel("Comparison Divider")
            .accessibilityValue("\(Int((split * 100).rounded())) percent reference")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: split = min(split + 0.05, 1)
                case .decrement: split = max(split - 0.05, 0)
                @unknown default: break
                }
            }
            .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
    }

    private func pane(_ image: NSImage?, label: String, size: CGSize) -> some View {
        ZoomableImage(image: image, pixelSize: size, viewport: app.viewport)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if image == nil {
                    ContentUnavailableView("No Image", systemImage: "photo", description: Text("This side doesn't exist."))
                }
            }
            .overlay(ZoomPanSurface(viewport: Bindable(app).viewport, onHover: { hover($0, pixelSize: size) }))
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

struct PixelProbe: Equatable {
    var x: Int
    var y: Int
}

/// Coordinates and both colours of the pixel under the pointer, with their visible difference.
struct PixelReadout: View {
    var probe: PixelProbe
    var before: PixelImage?
    var after: PixelImage?
    var beforeLabel: String
    var afterLabel: String

    var body: some View {
        let a = before?.color(x: probe.x, y: probe.y)
        let b = after?.color(x: probe.x, y: probe.y)
        HStack(spacing: DS.Space.m) {
            Text("x \(probe.x)  y \(probe.y)")
                .foregroundStyle(.secondary)
            swatch(a, label: beforeLabel)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            swatch(b, label: afterLabel)
            if let a, let b {
                let delta = a.perceptualDistance(to: b)
                Text(a == b ? "same" : String(format: "ΔE %.1f", delta))
                    .foregroundStyle(a == b ? Color.secondary : DS.Status.text(delta < 2.3 ? DS.Status.flaky : DS.Status.changed))
                    .help("CIE94 color difference. Below 2.3 is invisible to the eye.")
            }
        }
        .font(DS.Font.code.monospacedDigit())
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s - 2)
        .floatingGlassCapsule()
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func swatch(_ color: PixelColor?, label: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            PixelSwatch(color: color)
            Text(color?.hex ?? "none")
                .lineLimit(1)
                .fixedSize()
        }
        .help(label)
    }
}

/// One pixel's colour as a small square with a hairline edge, for the pixel readouts.
struct PixelSwatch: View {
    var color: PixelColor?

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color.map { Color(.sRGB, red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255,
                                    opacity: Double($0.a) / 255) } ?? .clear)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color(nsColor: .separatorColor)))
            .frame(width: 10, height: 10)
    }
}

/// − level +, plain on a glass bar (compare and single snapshot alike): no bordered boxes inside
/// a pill. The level is a menu of fixed steps.
struct ZoomControls: View {
    @Environment(AppModel.self) private var app

    private var label: String {
        let s = app.viewport.scale
        if abs(s - 1) < 0.01 { return "Fit" }
        return s >= 10 ? String(format: "%.0f×", s) : String(format: "%.1f×", s)
    }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Button { withAnimation(DS.motion) { app.viewport.zoomOut() } } label: { Image(systemName: "minus") }
                .help("Zoom out (⌘−)")
                .accessibilityLabel("Zoom Out")
            Menu {
                Button("Fit") { withAnimation(DS.motion) { app.viewport.reset() } }
                Divider()
                ForEach([2, 4, 8, 16], id: \.self) { factor in
                    Button("\(factor)×") {
                        // Keep the area being looked at centered while changing level.
                        withAnimation(DS.motion) { app.viewport.zoom(by: CGFloat(factor) / app.viewport.scale) }
                    }
                }
            } label: {
                Text(label).monospacedDigit().frame(minWidth: 34)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Zoom relative to fit. ⌘0 or double-click fits.")
            .accessibilityLabel("Zoom Level")
            .accessibilityValue(label)
            Button { withAnimation(DS.motion) { app.viewport.zoomIn() } } label: { Image(systemName: "plus") }
                .help("Zoom in (⌘=)")
                .accessibilityLabel("Zoom In")
        }
        .buttonStyle(.borderless)
        .modifier(QuietControlText())
        .fixedSize()
    }
}

/// Explains differences people can't easily see: invisible rendering noise, a few stray
/// pixels or a size change. Visible changes speak for themselves and get no note.
struct DiagnosisNote: View {
    var diagnosis: DiffDiagnosis
    @State private var copied = false

    var body: some View {
        if let icon {
            HStack(spacing: DS.Space.s) {
                Image(systemName: icon)
                    .foregroundStyle(DS.Status.flaky)
                    .accessibilityHidden(true)
                Text(diagnosis.summary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let suggestion = diagnosis.suggestion {
                    // An action, so it looks like the others: text and icon, not blue link text.
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(suggestion, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : suggestion, systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(DS.Font.code)
                    }
                    .fixedSize()
                    .quietControl()
                    .accessibilityLabel(copied ? "Copied" : "Copy \(suggestion)")
                    .help("The most lenient setting that passes this comparison. Prefer fixing the cause if you can.")
                }
            }
            .font(DS.Font.caption)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s - 2)
            .floatingGlass(in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .frame(maxWidth: 560)
            .padding(.horizontal, DS.Space.l)
            .accessibilityElement(children: .combine)
            .onChange(of: diagnosis) { copied = false }
        }
    }

    private var icon: String? {
        switch diagnosis.kind {
        case .imperceptible: "eye.slash"
        case .tiny: "sparkle.magnifyingglass"
        case .sizeChanged: "arrow.up.left.and.arrow.down.right"
        case .identical, .visible: nil
        }
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
            let rect = viewport.imageRect(imageSize: size, canvas: canvasSize)
            let scale = rect.width / max(size.width, 1)
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
    /// Pointer position and surface size while the pointer is over the surface; nil when it leaves.
    var onHover: ((point: CGPoint, canvas: CGSize)?) -> Void = { _ in }

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
        view.onHover = onHover
    }

    final class SurfaceView: NSView {
        var onChange: ((inout Viewport) -> Void) -> Void = { _ in }
        var onHover: ((point: CGPoint, canvas: CGSize)?) -> Void = { _ in }
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseMoved(with event: NSEvent) {
            onHover((convert(event.locationInWindow, from: nil), bounds.size))
        }

        override func mouseExited(with event: NSEvent) {
            onHover(nil)
        }

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
            onHover((convert(event.locationInWindow, from: nil), bounds.size))
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
