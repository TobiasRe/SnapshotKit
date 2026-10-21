import Foundation
import Testing
@testable import SnapshotKitCore

/// Test files as projects write them, each with the source the patch must produce, and the
/// round trip a record session relies on: the patch undone exactly, also with edits around it.
@Suite(.isolated) struct RecordPatcherCorpusTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var suite = "CardTests"
        var source: String
        var patched: String
        var testDescription: String { name }
    }

    static let xctestLine = "override func invokeTest() { withSnapshotTesting(record: .all) { super.invokeTest() } } // snapshotkit:record"

    static let cases: [Case] = [
        Case(name: "XCTest on the main actor", source: """
            import SnapshotTesting
            import XCTest

            @MainActor
            final class CardTests: XCTestCase, @unchecked Sendable {
                func testCard() {}
            }
            """, patched: """
            import SnapshotTesting
            import XCTest

            @MainActor
            final class CardTests: XCTestCase, @unchecked Sendable {
                \(xctestLine)
                func testCard() {}
            }
            """),
        Case(name: "XCTest with the brace on its own line and a base class of the project's", source: """
            import XCTest

            final class CardTests: SnapshotTestCase
            {
                func testCard() {}
            }
            """, patched: """
            import XCTest

            final class CardTests: SnapshotTestCase
            {
                \(xctestLine)
                func testCard() {}
            }
            """),
        // Swift 6 projects import XCTest this way; it's still XCTest, not a Swift Testing suite.
        Case(name: "XCTest imported @preconcurrency", source: """
            @preconcurrency import XCTest
            import SnapshotTesting

            final class CardTests: XCTestCase {
                func testCard() {}
            }
            """, patched: """
            @preconcurrency import XCTest
            import SnapshotTesting

            final class CardTests: XCTestCase {
                \(xctestLine)
                func testCard() {}
            }
            """),
        Case(name: "XCTest imported with an access level", source: """
            internal import XCTest

            final class CardTests: XCTestCase {
                func testCard() {}
            }
            """, patched: """
            internal import XCTest

            final class CardTests: XCTestCase {
                \(xctestLine)
                func testCard() {}
            }
            """),
        Case(name: "XCTest in a file that imports Swift Testing too", source: """
            import Testing
            import XCTest

            @Suite struct OtherTests {}

            final class CardTests: XCTestCase {
                func testCard() {}
            }
            """, patched: """
            import Testing
            import XCTest

            @Suite struct OtherTests {}

            final class CardTests: XCTestCase {
                \(xctestLine)
                func testCard() {}
            }
            """),
        Case(name: "a suite nested in an extension", source: """
            import Testing

            extension AllSnapshotTests {
                @Suite(.serialized)
                struct CardTests {
                    @Test func card() {}
                }
            }
            """, patched: """
            import Testing

            extension AllSnapshotTests {
                @Suite(.serialized, .snapshots(record: .all))
                struct CardTests {
                    @Test func card() {}
                }
            }
            """),
        Case(name: "a suite nested in another suite", source: """
            import Testing

            @Suite(.snapshots(record: .missing)) struct AllTests {
                @Suite struct CardTests {
                    @Test func card() {}
                }
            }
            """, patched: """
            import Testing

            @Suite(.snapshots(record: .missing)) struct AllTests {
                @Suite(.snapshots(record: .all)) struct CardTests {
                    @Test func card() {}
                }
            }
            """),
        Case(name: "a suite without @Suite inside #if, on the main actor", source: """
            #if os(iOS)
            import Testing

            @MainActor
            struct CardTests {
                @Test func card() {}
            }
            #endif
            """, patched: """
            #if os(iOS)
            import Testing

            @Suite(.snapshots(record: .all)) // snapshotkit:record
            @MainActor
            struct CardTests {
                @Test func card() {}
            }
            #endif
            """),
        Case(name: "a multi-line @Suite with a multi-line snapshots trait", source: """
            import Testing

            @Suite(
                "Cards",
                .snapshots(
                    record: .missing,
                    diffTool: .ksdiff
                )
            )
            @MainActor
            struct CardTests {}
            """, patched: """
            import Testing

            @Suite(
                "Cards",
                .snapshots(
                    record: .all,
                    diffTool: .ksdiff
                )
            )
            @MainActor
            struct CardTests {}
            """),
        Case(name: "@available and @MainActor around @Suite on one line", source: """
            import Testing

            @available(iOS 17, *) @MainActor @Suite(.snapshots(diffTool: .ksdiff)) final class CardTests {
                @Test func card() {}
            }
            """, patched: """
            import Testing

            @available(iOS 17, *) @MainActor @Suite(.snapshots(record: .all, diffTool: .ksdiff)) final class CardTests {
                @Test func card() {}
            }
            """),
        Case(name: "a diff tool closure in the trait", source: #"""
            import Testing

            @Suite(.snapshots(record: .failed, diffTool: .init { a, b in "ksdiff \(a.path(percentEncoded: false)) \(b.path)" }))
            struct CardTests {}
            """#, patched: #"""
            import Testing

            @Suite(.snapshots(record: .all, diffTool: .init { a, b in "ksdiff \(a.path(percentEncoded: false)) \(b.path)" }))
            struct CardTests {}
            """#),
        Case(name: "a comment between @Suite and the type", source: """
            import Testing

            @Suite(.snapshots(record: .missing))
            // Cards in every size.
            struct CardTests {}
            """, patched: """
            import Testing

            @Suite(.snapshots(record: .all))
            // Cards in every size.
            struct CardTests {}
            """),
        Case(name: "a doc comment with braces between @Suite and the type", source: """
            import Testing

            @Suite(.snapshots(record: .missing))
            /// Draws `{ }` placeholders.
            struct CardTests {}
            """, patched: """
            import Testing

            @Suite(.snapshots(record: .all))
            /// Draws `{ }` placeholders.
            struct CardTests {}
            """),
        Case(name: "a type named like the suite with more after it comes first", source: """
            import Testing

            struct CardTestsData {}
            struct CardTests {}
            """, patched: """
            import Testing

            struct CardTestsData {}
            @Suite(.snapshots(record: .all)) // snapshotkit:record
            struct CardTests {}
            """),
    ]

    @Test(arguments: cases)
    func patchesTheSuite(_ c: Case) throws {
        let patched = try RecordPatcher.patch(source: c.source, suite: c.suite)
        #expect(patched == c.patched)
    }

    /// What `RecordSession` keeps to undo the patch: the changed lines, found exactly once, so edits
    /// made during a run elsewhere in the file survive.
    @Test(arguments: cases)
    func thePatchCanBeUndoneAroundEdits(_ c: Case) throws {
        let patched = try RecordPatcher.patch(source: c.source, suite: c.suite)
        let file = PatchedFile(path: "CardTests.swift", suite: c.suite, original: c.source, patched: patched)
        #expect(patched.components(separatedBy: file.patchedSnippet).count == 2)
        let edited = "// edited during the run\n" + patched + "\n// and here\n"
        #expect(edited.replacingOccurrences(of: file.patchedSnippet, with: file.originalSnippet)
                == "// edited during the run\n" + c.source + "\n// and here\n")
    }

    /// Patching a Swift Testing suite twice (a second record before the first was restored) changes nothing more.
    @Test(arguments: cases.filter { !$0.patched.contains("invokeTest") })
    func patchingTwiceIsPatchingOnce(_ c: Case) throws {
        let once = try RecordPatcher.patch(source: c.source, suite: c.suite)
        let twice = try RecordPatcher.patch(source: once, suite: c.suite)
        #expect(twice.components(separatedBy: "record: .all").count == 2)
        #expect(!twice.contains("@Suite(.snapshots(record: .all)) // snapshotkit:record\n@Suite"))
    }
}
