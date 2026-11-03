// Xcode's Editor › SnapshotKit menu: show the test at the cursor in SnapshotKit, or re-record it.
// Embedded in SnapshotKit.app; the commands are in Info.plist.
import AppKit
import SnapshotKitCore
import XcodeKit

final class SourceEditorExtension: NSObject, XCSourceEditorExtension {}

/// Show Test and Re-record Test: hands the test around the cursor to SnapshotKit by URL. The
/// extension sees the file's text only; the app asks Xcode which project it is in.
final class TestCommand: NSObject, XCSourceEditorCommand {
    func perform(with invocation: XCSourceEditorCommandInvocation, completionHandler: @escaping (Error?) -> Void) {
        let lines = invocation.buffer.lines.compactMap { $0 as? String }
        let line = (invocation.buffer.selections.firstObject as? XCSourceTextRange)?.start.line ?? 0
        guard let action = invocation.commandIdentifier.split(separator: ".").last.flatMap({ TestRequest.Action(rawValue: String($0)) }),
              let test = SourceTest.at(line: line, in: lines) else {
            completionHandler(NSError(domain: "org.snapshotkit.SnapshotKit.XcodeExtension", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Put the cursor in a test, or in its suite."]))
            return
        }
        NSWorkspace.shared.open(TestRequest(action, test).url)
        completionHandler(nil)
    }
}
