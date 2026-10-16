import AppKit
import ApplicationServices
import SwiftUI
import Testing
@testable import SnapshotKit

extension AppUITests {
    /// Every control a VoiceOver user can reach must say what it is.
    @MainActor
    @Suite(.serialized)
    struct AccessibilityTests {
        init() {
            DS.solidSurfaces = true
            AppSnapshotTests.launchOnce()
        }

        /// Menu buttons (`AXMenuButton`) are left out: SwiftUI menus keep their title on an AppKit
        /// pull-down item that this in-process walk can't read, even for visibly titled ones. They all
        /// have text labels in code; check them with VoiceOver.
        static let interactiveRoles: Set<NSAccessibility.Role> = [.button, .popUpButton, .checkBox, .slider, .radioButton, .textField]

        /// Interactive elements with neither a label, title nor value. Uses KVC because SwiftUI's
        /// accessibility nodes are private NSObject subclasses.
        func unlabeled(in root: NSView) -> [String] {
            audit(root).unlabeled
        }

        /// Walks the tree; returns all interactive roles seen (to prove the walk works) and the unlabeled ones.
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

        func render(_ scenario: AppFixtures.Scenario, tab: ProjectTab, compare: CompareMode = .sideBySide) -> NSView {
            UserDefaults.standard.set(compare.rawValue, forKey: "compareMode")
            let store = AppFixtures.store()
            let app = AppModel(store: store)
            let project = AppFixtures.project(scenario, store: store)
            project.tab = tab
            app.show(project)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: ProjectView(project: project).environmentObject(app).frame(width: 1100, height: 700))
            window.contentView = hosting
            for _ in 0..<3 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
            return hosting
        }

        @Test(.enabled(if: AXIsProcessTrusted(), "SwiftUI only builds its accessibility tree for a trusted AX client"))
        func runTab() {
            let result = audit(render(.failedRun, tab: .run))
            #expect(result.interactive.count >= 5, "the walk should reach the run tab's controls")
            #expect(result.unlabeled == [])
        }

        @Test(.enabled(if: AXIsProcessTrusted()))
        func changesTab() {
            let result = audit(render(.changes, tab: .changes))
            #expect(result.interactive.count >= 5)
            #expect(result.unlabeled == [])
        }

        @Test(.enabled(if: AXIsProcessTrusted()))
        func failuresTabWithSlider() {
            let result = audit(render(.failures, tab: .failures, compare: .slider))
            #expect(result.interactive.count >= 5)
            #expect(result.unlabeled == [])
        }
    }
}

