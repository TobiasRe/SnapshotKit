import Foundation
import Testing
@testable import SnapshotKitCore

@Suite struct RecordPatcherTests {
    @Test func replacesExistingRecordValue() throws {
        let source = """
        @MainActor
        @Suite(.snapshots(record: .missing, diffTool: .default))
        struct CardTests {
            @Test func card() {}
        }
        """
        let patched = try RecordPatcher.patch(source: source, suite: "CardTests")
        #expect(patched.contains("@Suite(.snapshots(record: .all, diffTool: .default))"))
        #expect(!patched.contains(".missing"))
    }

    @Test func addsRecordToSnapshotsTrait() throws {
        let patched = try RecordPatcher.patch(source: "@Suite(\"Cards\", .snapshots(diffTool: .ksdiff)) struct CardTests {}", suite: "CardTests")
        #expect(patched == "@Suite(\"Cards\", .snapshots(record: .all, diffTool: .ksdiff)) struct CardTests {}")
    }

    @Test func appendsTraitToSuiteArguments() throws {
        #expect(try RecordPatcher.patch(source: "@Suite(.serialized) struct A {}", suite: "A") == "@Suite(.serialized, .snapshots(record: .all)) struct A {}")
        #expect(try RecordPatcher.patch(source: "@Suite() struct A {}", suite: "A") == "@Suite(.snapshots(record: .all)) struct A {}")
        #expect(try RecordPatcher.patch(source: "@Suite struct A {}", suite: "A") == "@Suite(.snapshots(record: .all)) struct A {}")
    }

    @Test func multiLineSuiteAttribute() throws {
        let source = "@Suite(\n    \"Cards\",\n    .serialized\n)\nstruct A {}"
        #expect(try RecordPatcher.patch(source: source, suite: "A") == "@Suite(\n    \"Cards\",\n    .serialized, .snapshots(record: .all)\n)\nstruct A {}")
    }

    @Test func insertsSuiteWhenMissing() throws {
        let source = "import Testing\n\n    @MainActor final class A {\n}\n"
        let patched = try RecordPatcher.patch(source: source, suite: "A")
        #expect(patched == "import Testing\n\n    @Suite(.snapshots(record: .all)) // snapshotkit:record\n    @MainActor final class A {\n}\n")
    }

    @Test func doesNotTouchOtherSuites() throws {
        let source = """
        @Suite(.snapshots(record: .missing)) struct Other {}
        struct Target {
            @Test func t() {}
        }
        """
        let patched = try RecordPatcher.patch(source: source, suite: "Target")
        #expect(patched.hasPrefix("@Suite(.snapshots(record: .missing)) struct Other {}"))
        #expect(patched.contains("@Suite(.snapshots(record: .all)) // snapshotkit:record\nstruct Target {"))
    }

    @Test func xctestOverridesInvokeTest() throws {
        let source = """
        import SnapshotTesting
        import XCTest

        final class CardTests: XCTestCase {
            func testCard() {}
        }
        """
        let patched = try RecordPatcher.patch(source: source, suite: "CardTests")
        #expect(patched.contains("final class CardTests: XCTestCase {\n    override func invokeTest() { withSnapshotTesting(record: .all) { super.invokeTest() } } // snapshotkit:record\n    func testCard()"))
        #expect(throws: RecordPatchError.self) { try RecordPatcher.patch(source: patched, suite: "CardTests") }
    }

    @Test func bracesInCommentsAndStringsDontEndTheClass() throws {
        let source = """
        import XCTest

        final class CardTests: XCTestCase {
            // } a closing brace in a comment
            /* } and /* nested */ } in a block comment */
            let a = "}\\"}", b = #"}"}"#, c = "\\\\"
            let d = \"\"\"
                }
                \"\"\"
            override func invokeTest() { super.invokeTest() }
        }
        """
        #expect(throws: RecordPatchError.xctestAlreadyOverridesInvokeTest(suite: "CardTests", file: "file")) {
            try RecordPatcher.patch(source: source, suite: "CardTests")
        }
    }

    @Test func parenthesesInSuiteStrings() throws {
        #expect(try RecordPatcher.patch(source: #"@Suite("a\\", .serialized) struct A {}"#, suite: "A")
                == #"@Suite("a\\", .serialized, .snapshots(record: .all)) struct A {}"#)
        #expect(try RecordPatcher.patch(source: ##"@Suite(#"say "hi"#, .serialized) struct A {}"##, suite: "A")
                == ##"@Suite(#"say "hi"#, .serialized, .snapshots(record: .all)) struct A {}"##)
    }

    @Test func missingDeclaration() {
        #expect(throws: RecordPatchError.declarationNotFound(suite: "Nope", file: "file")) {
            try RecordPatcher.patch(source: "struct Other {}", suite: "Nope")
        }
    }
}

@Suite(.serialized) struct RecordSessionTests {
    static let suiteSource = """
    import SnapshotTesting
    import Testing

    @Suite(.snapshots(record: .missing))
    struct CardTests {
        @Test func card() {}
    }
    """

    func makeRepo() throws -> TempRepo {
        let repo = try TempRepo()
        try repo.write("Tests/AppTests/CardTests.swift", Self.suiteSource)
        try repo.commitAll("init")
        return repo
    }

    let target = RecordSession.Target(suite: "CardTests", path: "Tests/AppTests/CardTests.swift")

    @Test func patchAndRestore() throws {
        let repo = try makeRepo()
        let session = try RecordSession.begin(repository: repo.url, targets: [target])
        #expect(try repo.read(target.path).contains("record: .all"))
        #expect(FileManager.default.fileExists(atPath: session.journalURL.path))
        #expect(PatchRegistry.shared.repositories().contains(repo.url.standardizedFileURL))

        let report = session.restore()
        #expect(report.files.map(\.outcome) == [.restored])
        #expect(try repo.read(target.path) == Self.suiteSource)
        #expect(!FileManager.default.fileExists(atPath: session.journalURL.path))
        #expect(try repo.git.status(paths: [target.path]).isEmpty)
        #expect(!PatchRegistry.shared.repositories().contains(repo.url.standardizedFileURL))
        // Idempotent.
        #expect(session.restore().files.map(\.outcome) == [.alreadyClean])
    }

    @Test func refusesUncommittedChanges() throws {
        let repo = try makeRepo()
        try repo.write(target.path, Self.suiteSource + "\n// local edit\n")
        #expect(throws: RecordPatchError.uncommittedChanges([target.path])) {
            try RecordSession.begin(repository: repo.url, targets: [target])
        }
        #expect(try repo.read(target.path).hasSuffix("// local edit\n"))
    }

    @Test func undoesOnlyThePatchWhenFileWasEditedDuringRun() throws {
        let repo = try makeRepo()
        let session = try RecordSession.begin(repository: repo.url, targets: [target])
        let edited = try repo.read(target.path) + "\n// added while recording\n"
        try repo.write(target.path, edited)

        let report = session.restore()
        #expect(report.files.map(\.outcome) == [.undidPatchKeepingEdits])
        #expect(try repo.read(target.path) == Self.suiteSource + "\n// added while recording\n")
    }

    @Test func conflictKeepsFileAndSavesBackup() throws {
        let repo = try makeRepo()
        let session = try RecordSession.begin(repository: repo.url, targets: [target])
        try repo.write(target.path, "completely rewritten\n")

        let report = session.restore()
        let conflict = try #require(report.conflicts.first)
        #expect(try repo.read(target.path) == "completely rewritten\n")
        #expect(try String(contentsOfFile: conflict.backup, encoding: .utf8) == Self.suiteSource)
    }

    @Test func restoresLeftoverFromCrashedProcess() throws {
        let repo = try makeRepo()
        let session = try RecordSession.begin(repository: repo.url, targets: [target])
        // Simulate a crash: the journal names a process that no longer exists.
        var journal = session.journal
        journal.processIdentifier = 999_999
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: session.journalURL)
        ActiveSessions.shared.remove(session)

        let reports = RecordSession.restoreAllLeftovers().reports.filter { $0.repository.standardizedFileURL.path == repo.url.standardizedFileURL.path }
        #expect(reports.first?.files.map(\.outcome) == [.restored])
        #expect(try repo.read(target.path) == Self.suiteSource)
        #expect(try RecordSession.restoreLeftover(repository: repo.url) == nil)
    }

    @Test func refusesWhileAnotherProcessOwnsThePatch() throws {
        let repo = try makeRepo()
        let session = try RecordSession.begin(repository: repo.url, targets: [target])
        ActiveSessions.shared.remove(session)
        // A live process named like the CLI owns the journal.
        let owner = try Self.startProcess(named: "snapkit")
        defer { owner.terminate() }
        var journal = session.journal
        journal.processIdentifier = owner.processIdentifier
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: session.journalURL)

        #expect(throws: RecordPatchError.patchAlreadyActive(repo.url.path)) {
            try RecordSession.restoreLeftover(repository: repo.url)
        }
        let all = RecordSession.restoreAllLeftovers()
        #expect(!all.reports.contains { $0.repository.path == repo.url.path })
        #expect(!all.failures.contains { $0.repository.path == repo.url.path })
        #expect(try repo.read(target.path).contains("record: .all"))

        let forced = try #require(try RecordSession.restoreLeftover(repository: repo.url, force: true))
        #expect(forced.files.map(\.outcome) == [.restored])
        #expect(try repo.read(target.path) == Self.suiteSource)
    }

    @Test func reportsLeftoversThatCannotBeRestored() throws {
        let repo = try makeRepo()
        let session = try RecordSession.begin(repository: repo.url, targets: [target])
        ActiveSessions.shared.remove(session)
        try Data("not a journal".utf8).write(to: session.journalURL)

        let failures = RecordSession.restoreAllLeftovers().failures.filter { $0.repository.path == repo.url.path }
        #expect(failures.count == 1)
        try FileManager.default.removeItem(at: session.journalURL)
        try repo.git.run(["checkout", "--", target.path])
    }

    @Test func beginRestoresALeftoverOfThisProcessFirst() throws {
        let repo = try makeRepo()
        _ = try RecordSession.begin(repository: repo.url, targets: [target])
        let second = try RecordSession.begin(repository: repo.url, targets: [target])
        #expect(try repo.read(target.path).contains("record: .all"))
        second.restore()
        #expect(try repo.read(target.path) == Self.suiteSource)
    }

    /// `sleep`, started through a link called `name`, which is what `ps` reports. (A copy of a system
    /// binary outside /bin gets killed by macOS soon after it starts.)
    static func startProcess(named name: String) throws -> Process {
        let dir = testTemp("bin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let executable = dir.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        return process
    }

    @Test func locatesSuiteFromFailureFileOrSearch() throws {
        let repo = try makeRepo()
        let viaFailure = SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [],
                                     failureFiles: [repo.url.appendingPathComponent(target.path).path])
        #expect(try SuiteLocator.locate(viaFailure, in: repo.url) == target.path)
        let viaSearch = SuiteResult(bundle: "AppTests", path: ["CardTests"], tests: [], failureFiles: ["/elsewhere/CardTests.swift"])
        #expect(try SuiteLocator.locate(viaSearch, in: repo.url) == target.path)
        let missing = SuiteResult(bundle: "AppTests", path: ["Nope"], tests: [], failureFiles: [])
        #expect(throws: RecordPatchError.self) { try SuiteLocator.locate(missing, in: repo.url) }
    }

    @Test func snippetsCoverWholeLines() {
        let (a, b) = PatchedFile.snippets(original: "one\ntwo(.x)\nthree", patched: "one\ntwo(.y)\nthree")
        #expect(a == "two(.x)")
        #expect(b == "two(.y)")
    }
}
