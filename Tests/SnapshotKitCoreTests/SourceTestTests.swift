import Foundation
import Testing
@testable import SnapshotKitCore

/// Xcode's editor extension finds the test at the cursor; the app finds its snapshots and failures.
@Suite(.isolated) struct SourceTestTests {
    static let source = #"""
        import SnapshotTesting
        import Testing

        /* struct NotASuite { func notATest() {} } */
        @Suite(.snapshots(record: .missing))
        struct CheckoutViewTests {
            let title = "func fake() { struct Fake {"

            @Test func payButton() {
                let view = PayButton { print("}") }
                assertSnapshot(of: view, as: .image)
                withSnapshotTesting(record: .all) {
                    assertSnapshot(of: view, as: .image(traits: .dark))
                }
            }

            @Test("Sized", arguments: [320, 768])
            func sized(width: Int)
            {
                assertSnapshot(of: Card(), as: .image(width: width))
            }

            struct Nested {
                class func helper() -> Int { 1 }
            }

            @Test func `pay button disabled`() {
                let text = """
                    } }
                    """
                assertSnapshot(of: text, as: .lines)
            }
        }

        func freeFunction() {}
        """#
    var lines: [String] { Self.source.components(separatedBy: "\n") }

    func test(at needle: String, offset: Int = 0) throws -> SourceTest? {
        let line = try #require(lines.firstIndex { $0.contains(needle) })
        return SourceTest.at(line: line + offset, in: lines)
    }

    @Test func findsTheFunctionTheCursorIsIn() throws {
        #expect(try test(at: "assertSnapshot(of: view") == SourceTest(suite: "CheckoutViewTests", function: "payButton"))
        #expect(try test(at: "traits: .dark") == SourceTest(suite: "CheckoutViewTests", function: "payButton"))
        #expect(try test(at: "@Test func payButton") == SourceTest(suite: "CheckoutViewTests", function: "payButton"))
        #expect(try test(at: "image(width: width)") == SourceTest(suite: "CheckoutViewTests", function: "sized"))
        #expect(try test(at: "as: .lines") == SourceTest(suite: "CheckoutViewTests", function: "`pay button disabled`"))
    }

    /// A function's brace on the next line, a closing brace in a string or a string spanning lines.
    @Test func followsBracesNotStringsOrComments() throws {
        #expect(try test(at: "func sized(width: Int)", offset: 1) == SourceTest(suite: "CheckoutViewTests", function: "sized"))
        #expect(try test(at: "    } }") == SourceTest(suite: "CheckoutViewTests", function: "`pay button disabled`"))
        #expect(try test(at: "let title") == SourceTest(suite: "CheckoutViewTests"))
    }

    @Test func betweenFunctionsItIsTheSuite() throws {
        #expect(try test(at: "@Test func payButton", offset: -1) == SourceTest(suite: "CheckoutViewTests"))
        #expect(try test(at: "class func helper") == SourceTest(suite: "Nested", function: "helper"))
        #expect(try test(at: "struct Nested", offset: 3) == SourceTest(suite: "CheckoutViewTests"))
    }

    @Test func outsideAnyTypeThereIsNone() throws {
        #expect(try test(at: "import Testing") == nil)
        #expect(try test(at: "func freeFunction") == nil)
        #expect(try test(at: "struct NotASuite") == nil)
    }

    /// Snapshots are named after the sanitized function, a parameterized test's with its labels.
    @Test func matchesItsSnapshotsAndRuns() {
        let pay = SourceTest(suite: "CheckoutViewTests", function: "payButton")
        let sized = SourceTest(suite: "CheckoutViewTests", function: "sized")
        let raw = SourceTest(suite: "CheckoutViewTests", function: "`pay button disabled`")
        func file(_ name: String) -> SnapshotFile { SnapshotFile(path: "Tests/AppTests/__Snapshots__/CheckoutViewTests/\(name)", byteSize: 1) }
        #expect(pay.recorded(file("payButton.1.png")))
        #expect(!pay.recorded(file("payButtonDisabled.1.png")))
        #expect(sized.recorded(file("sized-width.320.png")))
        #expect(raw.recorded(file("pay-button-disabled.1.png")))
        #expect(SourceTest(suite: "CheckoutViewTests").recorded(file("anything.1.png")))
        #expect(!SourceTest(suite: "ProfileTests").recorded(file("payButton.1.png")))

        let suite = SuiteResult(bundle: "AppTests", path: ["CheckoutViewTests"], tests: [], failureFiles: [])
        func ran(_ identifier: String) -> TestCaseResult {
            TestCaseResult(name: "Shown as anything", identifier: identifier, outcome: .failed, failureMessages: [], repetitions: [])
        }
        #expect(pay.ran(ran("CheckoutViewTests/payButton()"), in: suite))
        #expect(sized.ran(ran("CheckoutViewTests/sized(width:)"), in: suite))
        #expect(!pay.ran(ran("CheckoutViewTests/payButtonDisabled()"), in: suite))
        #expect(!SourceTest(suite: "ProfileTests", function: "payButton").ran(ran("CheckoutViewTests/payButton()"), in: suite))
    }

    @Test func travelsAsAURL() throws {
        let request = TestRequest(.rerecord, SourceTest(suite: "CheckoutViewTests", function: "`pay button`"))
        #expect(request.url.absoluteString.hasPrefix("snapshotkit://test?action=rerecord&suite=CheckoutViewTests&function="))
        #expect(TestRequest(url: request.url) == request)
        let suite = TestRequest(.show, SourceTest(suite: "CheckoutViewTests"))
        #expect(TestRequest(url: suite.url) == suite)
        #expect(TestRequest(url: URL(string: "snapshotkit://test?action=delete&suite=A")!) == nil)
        #expect(TestRequest(url: URL(string: "snapshotkit://test?action=show")!) == nil)
        #expect(TestRequest(url: URL(string: "snapshotkit://compare?action=show&suite=A")!) == nil)
    }
}
