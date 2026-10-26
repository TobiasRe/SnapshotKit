import SnapshotKitCore
import SwiftUI

/// Zoom, pan and the keys passed on to one window's compare view. The main window uses the app's;
/// each compare window (`snapkit open`) has its own, so zooming or flipping in one window leaves
/// the others alone. The View menu acts on the key window's (`AppModel.activeCompare`).
@Observable
@MainActor
final class CompareState {
    /// Driven by the compare bar and ⌘= / ⌘− / ⌘0.
    var viewport = Viewport()
    /// Bumped by View ▸ Zoom to Change; the compare view frames the changed pixels.
    var zoomToChangeRequest = 0
    /// A key the list beside the compare view passes on to it: Space flips the images in Toggle
    /// mode, ← and → move the slider, so they work without focusing the image.
    private(set) var key = CompareKeyRequest(key: .flip, count: 0)

    func pass(_ key: CompareKeyRequest.Key) {
        self.key = CompareKeyRequest(key: key, count: self.key.count + 1)
    }
}

/// See `CompareState.pass(_:)`; `count` makes the same key pressed twice a new request.
struct CompareKeyRequest: Equatable {
    enum Key { case flip, left, right }
    var key: Key
    var count: Int
}

extension EnvironmentValues {
    /// A compare window's own state; nil in the main window, which uses the app's.
    @Entry var compareState: CompareState?
}
