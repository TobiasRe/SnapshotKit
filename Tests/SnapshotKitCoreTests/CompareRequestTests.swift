import Foundation
import Testing
@testable import SnapshotKitCore

/// `snapkit open` (swift-snapshot-testing's diff tool) hands the pair to the app as a URL.
@Suite(.isolated) struct CompareRequestTests {
    @Test func survivesTheURLWithAwkwardPaths() throws {
        let request = CompareRequest(reference: URL(fileURLWithPath: "/work/My App/Tests/__Snapshots__/A Tests/price+tax.dark mode.png"),
                                     actual: URL(fileURLWithPath: "/tmp/run #3/a&b=ü.png"))
        #expect(request.url.scheme == "snapshotkit")
        #expect(request.url.host == "compare")
        let decoded = try #require(CompareRequest(url: request.url))
        #expect(decoded == request)
        #expect(decoded.reference.path == "/work/My App/Tests/__Snapshots__/A Tests/price+tax.dark mode.png")
        #expect(decoded.actual.path == "/tmp/run #3/a&b=ü.png")
    }

    @Test func ignoresOtherURLs() {
        #expect(CompareRequest(url: URL(string: "https://example.com/compare?reference=/a.png&actual=/b.png")!) == nil)
        #expect(CompareRequest(url: URL(string: "snapshotkit://open?reference=/a.png&actual=/b.png")!) == nil)
        #expect(CompareRequest(url: URL(string: "snapshotkit://compare?reference=/a.png")!) == nil)
        #expect(CompareRequest(url: URL(string: "snapshotkit://compare?reference=&actual=/b.png")!) == nil)
    }

    @Test func findsTheReferenceInItsRepository() throws {
        let repo = try TempRepo()
        try repo.write("Tests/AppTests/__Snapshots__/CheckoutTests/pay.dark.png", Data([0]))
        let request = CompareRequest(reference: repo.url.appendingPathComponent("Tests/AppTests/__Snapshots__/CheckoutTests/pay.dark.png"),
                                     actual: URL(fileURLWithPath: "/tmp/pay.png"))
        let location = try #require(request.location)
        #expect(location.repository.resolvingSymlinksInPath().path == repo.url.resolvingSymlinksInPath().path)
        #expect(location.path == "Tests/AppTests/__Snapshots__/CheckoutTests/pay.dark.png")
    }

    @Test func aReferenceOutsideARepositoryHasNoLocation() throws {
        let dir = testTemp("loose")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let request = CompareRequest(reference: dir.appendingPathComponent("a.png"), actual: dir.appendingPathComponent("b.png"))
        #expect(request.location == nil)
    }
}
