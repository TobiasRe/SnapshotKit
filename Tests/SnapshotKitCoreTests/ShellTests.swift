import Foundation
import Testing
@testable import SnapshotKitCore

@Suite(.isolated) struct ShellTests {
    let large = Data(repeating: UInt8(ascii: "x"), count: 1 << 20)

    @Test func inputToAChildThatExitsWithoutReadingIt() throws {
        let result = try Shell.run(["true"], input: large)
        #expect(result.succeeded)
        #expect(try Shell.run(["head", "-c", "3"], input: large).stdout == "xxx")
    }

    @Test func inputLargerThanAPipeWhileTheChildWrites() throws {
        let result = try Shell.run(["cat"], input: large)
        #expect(result.stdout.utf8.count == large.count)
    }

    @Test func failedDataCommandsReportTheirStandardError() throws {
        let error = try #require(throws: CommandError.self) {
            try Shell.data(["ls", "/no/such/folder"])
        }
        #expect(error.result.stderr.contains("No such file"))
    }

    /// Not "`git rev-parse` exited with 127: env: git: No such file or directory", nor, from the
    /// CLI, "… is not inside a git repository".
    @Test func aCommandMissingFromThePathSaysSo() throws {
        let command = ["git", "rev-parse", "--show-toplevel"]
        let result = try Shell.run(command, environment: ["PATH": "/no/such/bin"])
        let error = CommandError(command: command, result: result)
        #expect(error.isNotFound)
        #expect(error.errorDescription?.hasPrefix("`git` was not found on the PATH (") == true)
        #expect(error.errorDescription?.hasSuffix(". Install Xcode or its command line tools (`xcode-select --install`).") == true)
        #expect(throws: CommandError.self) { try Git.repository(at: URL(fileURLWithPath: "/"), environment: ["PATH": "/no/such/bin"]) }
    }

    @Test func quotesOnlyWhatTheShellWouldSplit() {
        #expect(Shell.quote("-only-testing:App/Card_1") == "-only-testing:App/Card_1")
        #expect(Shell.quote("") == "''")
        #expect(Shell.quote("iPhone 16 Pro") == "'iPhone 16 Pro'")
        #expect(Shell.quote("it's") == #"'it'\''s'"#)
        #expect(Shell.quote("$HOME") == "'$HOME'")
    }

    /// A command runs at its caller's quality of service, as do the threads draining it. `ps` shows only
    /// background apart (priority 4, the others 31), so the caller here is a background thread.
    @Test func runsAtTheCallersQualityOfService() async throws {
        let priority = try await withCheckedThrowingContinuation { continuation in
            let caller = Thread {
                continuation.resume(with: Result { try Shell.output(["sh", "-c", "ps -o pri= -p $$"]) })
            }
            caller.qualityOfService = .background
            caller.start()
        }
        #expect(priority == "4")
    }

    @Test func runsBlockingWorkOffThePool() async throws {
        let value = try await offCooperativePool { try Shell.output(["echo", "hi"]) }
        #expect(value == "hi")
    }
}

@Suite(.isolated) struct LineBufferTests {
    @Test func splitsAtNewlinesAndCarriageReturnsAndDropsBlankLines() {
        let buffer = LineBuffer()
        #expect(buffer.append(Data("one\ntw".utf8)) == ["one"])
        #expect(buffer.append(Data("o\r\n\nthree\rfour".utf8)) == ["two", "three"])
        #expect(buffer.flush() == ["four"])
        #expect(buffer.flush().isEmpty)
    }

    @Test func keepsMultiByteCharactersSplitAcrossReads() {
        let buffer = LineBuffer()
        let bytes = Array("größe\n".utf8)
        #expect(buffer.append(Data(bytes[..<3])).isEmpty)
        #expect(buffer.append(Data(bytes[3...])) == ["größe"])
    }
}
