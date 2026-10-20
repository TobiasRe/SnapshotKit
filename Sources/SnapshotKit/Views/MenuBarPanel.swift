import AppKit
import SnapshotKitCore
import SwiftUI

/// The menu bar icon: a pie that fills as tests complete while something runs; otherwise the app
/// symbol, with the failing count from the last runs.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if let path = model.runningPaths.first, let project = model.projectModel(path: path) {
            RunningMenuBarLabel(project: project)
        } else {
            let failing = model.failingCounts.values.reduce(0, +)
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "photo.stack")
                if failing > 0 { Text("\(failing)").monospacedDigit() }
            }
            .accessibilityLabel(failing > 0 ? "SnapshotKit, \(failing) failing" : "SnapshotKit")
        }
    }
}

private struct RunningMenuBarLabel: View {
    let project: ProjectModel

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(nsImage: ProgressPie.image(fraction: project.progressFraction))
            Text(MenuBarPanel.countText(project)).monospacedDigit()
        }
        .accessibilityLabel("SnapshotKit, \(project.stageLabel)")
    }
}

/// A 16 pt template image: a ring with a pie filled to `fraction`, or a quarter arc while the
/// total isn't known yet. Template images take the menu bar's colour in light and dark.
enum ProgressPie {
    static func image(fraction: Double?) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.5
            NSColor.black.setStroke()
            ring.stroke()
            let center = NSPoint(x: rect.midX, y: rect.midY), radius = rect.width / 2 - 3.5
            let pie = NSBezierPath()
            if let fraction {
                guard fraction > 0 else { return true }
                pie.move(to: center)
                pie.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                pie.close()
                NSColor.black.setFill()
                pie.fill()
            } else {
                pie.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
                pie.lineWidth = 2
                pie.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The menu bar panel: what's running, recent projects, and the way back into the app.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    static let width: CGFloat = 340

    /// "12/40" while the total is known, "12" before.
    static func countText(_ project: ProjectModel) -> String {
        let done = project.passed + project.failed + project.skipped
        if let total = project.expectedTotal, total > 0, project.phase == .testing { return "\(min(done, total))/\(total)" }
        return done > 0 ? "\(done)" : ""
    }

    /// Projects needing attention first (failing), then pinned, then recent.
    private var quickProjects: [Project] {
        let pinned = model.store.settings.pinned, recents = model.store.settings.recents
        let failing = model.failingCounts.filter { $0.value > 0 }.keys.sorted()
        var seen = Set<String>()
        return (failing + pinned + recents).compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            return model.projects.first { $0.path == path }
        }
        .prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.runningPaths.isEmpty {
                Label("Nothing running", systemImage: "checkmark.circle")
                    .font(DS.Font.secondary)
                    .foregroundStyle(.secondary)
                    .padding(DS.Space.m)
            } else {
                ForEach(model.runningPaths, id: \.self) { path in
                    if let project = model.projectModel(path: path) {
                        RunProgressRow(project: project) { show(path) }
                    }
                }
            }
            Divider()
            Text("Projects")
                .font(DS.Font.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.m)
                .padding(.top, DS.Space.s)
            ForEach(quickProjects) { project in
                QuickProjectRow(project: project,
                                failing: model.failingCounts[project.path] ?? 0,
                                running: model.runningPaths.contains(project.path),
                                open: { show(project.path) },
                                run: { model.runTests(path: project.path) })
            }
            if quickProjects.isEmpty {
                Text("Add a project in the app first.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(.secondary)
                    .padding(DS.Space.m)
            }
            Divider().padding(.top, DS.Space.xs)
            HStack {
                // The panel's main action: primary text, not a tinted link, beside quieter Settings and Quit.
                Button("Open SnapshotKit") { show(nil) }
                    .foregroundStyle(.primary)
                Spacer()
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(DS.Space.m)
        }
        .frame(width: Self.width)
    }

    /// Brings the main window forward, opening it if it was closed, and selects `path`.
    private func show(_ path: String?) {
        if let path { model.open(path: path) }
        if !NSApp.windows.contains(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    }
}

/// One running project: what it's doing, how far along, and Cancel.
struct RunProgressRow: View {
    let project: ProjectModel
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: open) {
                    Text(project.project.name).font(DS.Font.heading).lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Show in SnapshotKit")
                Spacer()
                Button { project.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel")
                    .accessibilityLabel("Cancel \(project.project.name)")
            }
            Text(project.stageLabel).font(DS.Font.secondary).foregroundStyle(.secondary).lineLimit(1)
            if let fraction = project.progressFraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack(spacing: DS.Space.m) {
                // The icons carry the status colors; the numbers stay readable, as on the Run tab.
                Label { Text("\(project.passed)") } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Status.passed)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(project.passed) passed")
                Label { Text("\(project.failed)") } icon: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(project.failed > 0 ? DS.Status.failed : .secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(project.failed) failed")
                Spacer()
                if let started = project.startedAt {
                    Text(started, style: .timer).foregroundStyle(.secondary)
                }
            }
            .font(DS.Font.caption.monospacedDigit())
            if let test = project.currentTest {
                Text(test).font(DS.Font.code).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(DS.Space.m)
    }
}

/// A project with its failing count; click to open, play to run its tests.
struct QuickProjectRow: View {
    var project: Project
    var failing: Int
    var running: Bool
    var open: () -> Void
    var run: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Button(action: open) {
                HStack(spacing: DS.Space.s) {
                    ProjectMonogram(name: project.name)
                    Text(project.name).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    if failing > 0 { FailingCount(count: failing) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(project.name)")
            Button(action: run) { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .disabled(running)
                .help("Run its snapshot tests")
                .accessibilityLabel("Run \(project.name)")
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.xs + 1)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(hovering ? DS.Surface.hover : .clear)
            .padding(.horizontal, DS.Space.xs))
        .onHover { hovering = $0 }
    }
}
