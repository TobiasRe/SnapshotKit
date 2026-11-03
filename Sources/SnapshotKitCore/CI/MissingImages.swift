import Foundation

/// Why a failing test shows no images, worded for its detail: what was tried and didn't work, or what kind of
/// failure it is. Only "not a snapshot failure" when its message isn't swift-snapshot-testing's.
public struct MissingImages: Equatable, Sendable {
    public var title: String
    public var reason: String

    public init(title: String, reason: String) {
        self.title = title
        self.reason = reason
    }

    /// `messages` are the test's failure messages, `images` its images (or just the attempt shown).
    public static func explain(messages: [String], images: [SnapshotFailureImages]) -> MissingImages {
        var reasons: [String] = []
        for image in images {
            for reason in [image.referenceMissing.map { "Reference: \($0)" }, image.failureMissing.map { "Actual: \($0)" }]
            where reason != nil && !reasons.contains(reason!) {
                reasons.append(reason!)
            }
        }
        if !reasons.isEmpty { return MissingImages(title: "Images Not Available", reason: reasons.joined(separator: "\n")) }

        let messages = messages.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !messages.isEmpty else {
            return MissingImages(title: "No Failure Message",
                                 reason: "There is no failure message for this test, so which images it compared is unknown. A CI job has "
                                    + "the messages only in its test report (`artifacts: reports: junit:`).")
        }
        let mismatches = messages.flatMap(SnapshotMismatch.parse)
        if mismatches.contains(where: \.namesImages) {
            return mismatches.contains(where: \.isImage)
                ? MissingImages(title: "Images Not Found", reason: "The failure message names its images, but none of them could be found.")
                : MissingImages(title: "Text Snapshot", reason: "This snapshot is text, not an image: the difference is in the failure message.")
        }
        if messages.contains(where: SnapshotMismatch.isSnapshotFailure) {
            return MissingImages(title: "Images Not Named",
                                 reason: "The failure message says a snapshot didn’t match, but not where its images are: swift-snapshot-testing "
                                    + "writes their paths after “@−” and “@+”, or on a diff tool’s command line. A test report that cuts long "
                                    + "messages short loses them.")
        }
        return MissingImages(title: "Not a Snapshot Failure",
                             reason: "This test failed for another reason than a snapshot that doesn’t match, so there are no images to compare.")
    }
}
