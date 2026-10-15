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

    private var mode: CompareMode { CompareMode(rawValue: modeRaw) ?? .sideBySide }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                if let pair {
                    content(pair)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(CheckerboardBackground())
            .clipped()
        }
        .task(id: identity) {
            pair = nil
            let load = load
            pair = await Task.detached {
                let (before, after) = load()
                return ComparePair.make(before: before, after: after)
            }.value
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $modeRaw) {
                ForEach(CompareMode.allCases) { m in
                    Label(m.rawValue, systemImage: m.systemImage).tag(m.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if let stats = pair?.stats {
                Group {
                    if stats.isIdentical {
                        Label("Identical pixels", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Label(String(format: "%d px differ (%.2f%%)%@", stats.changedPixels, stats.changedFraction * 100,
                                     stats.sizeChanged ? " · size changed" : ""), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }
            if let size = pair?.pixelSize, size.width > 0 {
                Text("\(Int(size.width))×\(Int(size.height)) px").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { app.viewport.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (⌘−)")
            Text("\(Int((app.viewport.scale * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)
            Button { app.viewport.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (⌘=)")
            Button { app.viewport.reset() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Fit (⌘0, or double-click the image)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
            VStack(spacing: 0) {
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        ZoomableImage(image: pair.after, pixelSize: pair.pixelSize, viewport: app.viewport)
                        ZoomableImage(image: pair.before, pixelSize: pair.pixelSize, viewport: app.viewport)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geo.size.width * split)
                            }
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2)
                            .offset(x: geo.size.width * split - 1)
                        caption(beforeLabel).padding(8)
                        caption(afterLabel).frame(maxWidth: .infinity, alignment: .trailing).padding(8)
                    }
                    .overlay(ZoomPanSurface(viewport: $app.viewport))
                }
                HStack {
                    Text(beforeLabel).font(.caption)
                    Slider(value: $split, in: 0...1)
                    Text(afterLabel).font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        case .difference:
            pane(pair.diff ?? pair.after ?? pair.before,
                 label: pair.diff == nil ? "Only one side exists" : "Changed pixels in magenta",
                 size: pair.pixelSize)
        }
    }

    private func pane(_ image: NSImage?, label: String, size: CGSize) -> some View {
        ZoomableImage(image: image, pixelSize: size, viewport: app.viewport)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if image == nil { Text("No image").foregroundStyle(.secondary) }
            }
            .overlay(alignment: .topLeading) { caption(label).padding(8) }
            .overlay(ZoomPanSurface(viewport: $app.viewport))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
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
            let fit = Viewport.fitScale(image: size, in: CGSize(width: canvasSize.width - 24, height: canvasSize.height - 24))
            let scale = fit * viewport.scale
            let drawn = CGSize(width: size.width * scale, height: size.height * scale)
            let rect = CGRect(
                x: canvasSize.width / 2 + viewport.offset.width - drawn.width / 2,
                y: canvasSize.height / 2 + viewport.offset.height - drawn.height / 2,
                width: drawn.width, height: drawn.height
            )
            // Nearest-neighbour when zoomed in so individual pixels stay crisp.
            context.draw(Image(nsImage: image).interpolation(scale >= 2 ? .none : .high), in: rect)
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
            let dark = Color.gray.opacity(0.12)
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
