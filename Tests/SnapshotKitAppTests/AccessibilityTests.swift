import AppKit
import ApplicationServices
import os
import SwiftUI
import Testing
@testable import SnapshotKitUI

extension AppUITests {
    /// Every control a VoiceOver user can reach must say what it is.
    @MainActor
    @Suite(.serialized, .enabled(if: AXIsProcessTrusted(), "SwiftUI only builds its accessibility tree for a trusted AX client"))
    struct AccessibilityTests {
        init() {
            DS.solidSurfaces = true
            AppSnapshotTests.launchOnce()
            AppFixtures.resetDefaults()
        }

        /// Menu buttons (`AXMenuButton`) are left out: SwiftUI menus keep their title on an AppKit
        /// pull-down item that this in-process walk can't read, even for visibly titled ones. They all
        /// have text labels in code; check them with VoiceOver.
        static let interactiveRoles: Set<NSAccessibility.Role> = [.button, .popUpButton, .checkBox, .slider, .radioButton, .textField]

        /// Walks the tree; returns all interactive roles seen (to prove the walk works) and the ones with
        /// neither a label, title nor value. Uses KVC because SwiftUI's accessibility nodes are private
        /// NSObject subclasses.
        func audit(_ root: NSView) -> (interactive: [String], unlabeled: [String]) {
            // Asking through the AX API makes SwiftUI build its accessibility tree.
            var windows: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &windows)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            var interactive: [String] = []
            var found: [String] = []
            var visited = 0
            func get<T>(_ object: NSObject, _ key: String) -> T? {
                guard object.responds(to: NSSelectorFromString(key)) else { return nil }
                return object.value(forKey: key) as? T
            }
            func visit(_ element: Any, depth: Int) {
                visited += 1
                guard depth < 40, visited < 5000, let el = element as? NSObject else { return }
                let role: String? = get(el, "accessibilityRole")
                let isElement: Bool = get(el, "isAccessibilityElement") ?? true
                let size: NSRect = (get(el, "accessibilityFrame") as NSValue?)?.rectValue ?? .zero
                // Ignore split-view divider internals and other zero-size helpers.
                if let role, isElement, size.width > 8, size.height > 8, Self.interactiveRoles.contains(NSAccessibility.Role(rawValue: role)) {
                    let label: String = get(el, "accessibilityLabel") ?? get(el, "accessibilityTitle") ?? ""
                    interactive.append("\(role):\(label)")
                    // VoiceOver also reads a control's child text (menu buttons put their title there).
                    func descendantTexts(_ node: NSObject, depth: Int) -> [String] {
                        guard depth < 4 else { return [] }
                        let own: [String] = [get(node, "accessibilityLabel"), get(node, "accessibilityTitle"), get(node, "accessibilityValue")].compactMap { $0 }
                        let children = (get(node, "accessibilityChildren") as [Any]?) ?? []
                        return own + children.compactMap { $0 as? NSObject }.flatMap { descendantTexts($0, depth: depth + 1) }
                    }
                    let texts = descendantTexts(el, depth: 0)
                    if texts.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        let help: String = get(el, "accessibilityHelp") ?? ""
                        let frame: NSRect = (get(el, "accessibilityFrame") as NSValue?)?.rectValue ?? .zero
                        let rootFrame = root.window?.convertToScreen(root.convert(root.bounds, to: nil)) ?? .zero
                        found.append("\(role) help=\(help) at=(\(Int(frame.minX - rootFrame.minX)),\(Int(rootFrame.maxY - frame.maxY)) \(Int(frame.width))x\(Int(frame.height)))")
                    }
                }
                for child in (get(el, "accessibilityChildren") as [Any]?) ?? [] { visit(child, depth: depth + 1) }
            }
            visit(root, depth: 0)
            return (interactive, found)
        }

        /// Audits the project pane showing `section`.
        func audit(_ scenario: AppFixtures.Scenario, section: ProjectSection, compare: CompareMode = .sideBySide) -> (interactive: [String], unlabeled: [String]) {
            AppFixtures.defaults.set(compare.rawValue, forKey: "compareMode")
            let store = AppFixtures.store()
            let app = AppModel(store: store)
            let project = AppFixtures.project(scenario, store: store)
            project.section = section
            app.show(project)
            return AppFixtures.host(ProjectView(project: project).environment(app)) { audit($0) }
        }

        @Test func runTab() {
            let result = audit(.failedRun, section: .run)
            #expect(result.interactive.count >= 5, "the walk should reach the Run view’s controls")
            #expect(result.unlabeled == [])
        }

        @Test func snapshotsTab() {
            let result = audit(.library, section: .library)
            #expect(result.interactive.count >= 5)
            #expect(result.unlabeled == [])
        }

        @Test func snapshotsGrid() {
            AppFixtures.defaults.set(LibraryLayout.grid.rawValue, forKey: "libraryLayout")
            let result = audit(.library, section: .library)
            #expect(result.interactive.count >= 5)
            #expect(result.unlabeled == [])
        }

        @Test func changesTab() {
            let result = audit(.changes, section: .comparison)
            #expect(result.interactive.count >= 5)
            #expect(result.unlabeled == [])
        }

        /// Every description and value in this app's windows, read through the Accessibility API as
        /// VoiceOver does: unlike the in-process walk above, that reaches a list's rows. The main thread
        /// answers those queries, so they run on another thread while it keeps its run loop going.
        func spokenTexts(inWindowTitled title: String) -> [String] {
            // Handed back under a lock: the main queue can't take a block while this test runs on it.
            let walk = OSAllocatedUnfairLock(initialState: (texts: [String](), done: false))
            Thread.detachNewThread {
                func string(_ element: AXUIElement, _ attribute: String) -> String? {
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
                    return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
                }
                var texts: [String] = []
                func visit(_ element: AXUIElement, depth: Int) {
                    guard depth < 40 else { return }
                    texts += [kAXDescriptionAttribute, kAXValueAttribute].compactMap { string(element, $0) }
                    var children: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                    for child in (children as? [AXUIElement]) ?? [] { visit(child, depth: depth + 1) }
                }
                let app = AXUIElementCreateApplication(getpid())
                AXUIElementSetMessagingTimeout(app, 0.5)
                var windows: CFTypeRef?
                AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
                for window in (windows as? [AXUIElement]) ?? [] where string(window, kAXTitleAttribute) == title {
                    visit(window, depth: 0)
                }
                let result = texts
                walk.withLock { $0 = (result, true) }
            }
            let deadline = Date().addingTimeInterval(20)
            while !walk.withLock(\.done), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return walk.withLock(\.texts)
        }

        /// What VoiceOver can read of `view`, hosted in a window on screen (only those are in the app's
        /// accessibility tree), off to the side.
        func spokenTexts<V: View>(_ view: V, size: CGSize) -> [String] {
            AppFixtures.host(view, size: size) { hosted in
                hosted.window?.title = "probe"
                hosted.window?.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
                hosted.window?.orderFrontRegardless()
                defer { hosted.window?.orderOut(nil) }
                return spokenTexts(inWindowTitled: "probe")
            }
        }

        /// A project row is one VoiceOver stop that names the project with its failing count, not a
        /// name and then a bare "3 failing" with nothing to say whose.
        @Test func switcherRowSaysWhoseFailuresTheyAre() {
            let app = AppModel(store: AppFixtures.store())
            app.failingCounts = ["/work/payments-ui": 3]
            let found = spokenTexts(ProjectSwitcherList(close: {}).environment(app), size: CGSize(width: 300, height: 340))
            #expect(found.contains("payments-ui, 3 failing"), "\(found)")
            #expect(!found.contains("3 failing"))
        }

        /// A section reads by its full name and what its count counts: "Changes vs develop", not "vs
        /// develop"; "2 failing tests", not a bare number.
        @Test func sidebarSectionsSayWhatTheyCount() {
            let store = AppFixtures.store()
            let app = AppModel(store: store)
            app.show(AppFixtures.project(.failures, store: store))
            let found = spokenTexts(SidebarView().environment(app), size: CGSize(width: 260, height: 420))
            #expect(found.contains("Changes vs develop"), "\(found)")
            #expect(found.contains("Last Run"), "\(found)")
            #expect(found.contains("2 failing tests"), "\(found)")
            #expect(!found.contains("vs develop"))
        }

        @Test func failuresTabWithSlider() {
            let result = audit(.failures, section: .lastRun, compare: .slider)
            #expect(result.interactive.count >= 5)
            #expect(result.unlabeled == [])
        }
    }
}

