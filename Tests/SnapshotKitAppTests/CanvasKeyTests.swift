import AppKit
import SnapshotKitCore
import SwiftUI
import Testing
@testable import SnapshotKitUI

extension AppUITests {
    /// With the image in focus (clicked), ↑ and ↓ step through the list beside it, one snapshot after
    /// another: also after a step that showed a spinner while the next images were decoded, which
    /// took the image, and the keyboard with it, away.
    @MainActor
    @Suite(.serialized)
    struct CanvasKeyTests {
        init() {
            DS.solidSurfaces = true
            AppSnapshotTests.launchOnce()
            AppFixtures.resetDefaults()
        }

        @Test func downArrowOnTheImageStepsThroughTheLibrary() async throws {
            try await expectSteps(.library, section: .library) { $0.selectedSnapshotID }
        }

        @Test func downArrowOnTheImageStepsThroughChanges() async throws {
            try await expectSteps(.changes, section: .comparison) { $0.selectedChangeID }
        }

        @Test func downArrowOnTheImageStepsThroughFailures() async throws {
            try await expectSteps(.failures, section: .lastRun) { $0.selectedFailureID }
        }

        private func expectSteps(_ scenario: AppFixtures.Scenario, section: ProjectSection, selection: (ProjectModel) -> String?,
                                 sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let store = AppFixtures.store()
            let app = AppModel(store: store)
            let project = AppFixtures.project(scenario, store: store)
            project.section = section
            app.show(project)
            // As in the app: nothing decoded yet, so each step shows a snapshot that is still loading.
            ComparePairCache.shared.removeAllObjects()
            SnapshotImageCache.shared.removeAllObjects()
            // Hosted here rather than with `AppFixtures.host`: the images load asynchronously, which
            // needs the main actor free while waiting.
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSHostingView(rootView: ProjectView(project: project).environment(app).defaultAppStorage(AppFixtures.defaults))
            root.frame = window.contentLayoutRect
            window.contentView = root
            try await settle(root)
            let surface = try #require(surfaces(in: root).first, "no image surface", sourceLocation: sourceLocation)
            window.makeFirstResponder(surface)
            var seen = [selection(project)]
            for key in [125, 126] as [UInt16] {            // ↓, then ↑ back
                ComparePairCache.shared.removeAllObjects()
                SnapshotImageCache.shared.removeAllObjects()
                window.sendEvent(Self.arrow(key, in: window))
                try await settle(root)
                seen.append(selection(project))
            }
            #expect(seen[1] != seen[0] && seen[2] == seen[0], "↓ then ↑ on the image selected \(seen)", sourceLocation: sourceLocation)
        }

        /// Lets the selection's images load, and the view settle around them.
        private func settle(_ root: NSView) async throws {
            for _ in 0..<50 {
                root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
                if ImageDecoding.pending == 0 && !surfaces(in: root).isEmpty { break }
            }
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }

        private func surfaces(in view: NSView) -> [NSView] {
            (view is ZoomPanSurface.SurfaceView ? [view] : []) + view.subviews.flatMap { surfaces(in: $0) }
        }

        /// ↓ (key code 125) or ↑ (126), as the keyboard sends it.
        private static func arrow(_ keyCode: UInt16, in window: NSWindow) -> NSEvent {
            let function = keyCode == 125 ? NSDownArrowFunctionKey : NSUpArrowFunctionKey
            let key = String(Character(UnicodeScalar(UInt16(function))!))
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: key,
                                    charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)!
        }
    }
}
