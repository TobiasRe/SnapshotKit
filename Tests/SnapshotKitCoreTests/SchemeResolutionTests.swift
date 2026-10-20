import Foundation
import Testing
@testable import SnapshotKitCore

/// Without a scheme from CI or `.snapshotkit.yml`, the one `xcodebuild -list` reports is used.
@Suite struct SchemeResolutionTests {
    /// A runner whose `xcodebuild` prints `output` for `-list -json` and records its arguments.
    func runner(listing output: String, config: SnapshotConfig = SnapshotConfig()) throws -> (TestRunner, URL) {
        let dir = testTemp("xcodebuild")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let xcodebuild = dir.appendingPathComponent("xcodebuild"), arguments = dir.appendingPathComponent("arguments")
        try "#!/bin/sh\necho \"$@\" > '\(arguments.path)'\ncat <<'JSON'\n\(output)\nJSON\n".write(to: xcodebuild, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcodebuild.path)
        let environment = TestEnvironment(xcode: XcodeInstall(path: "/Applications/Xcode.app", version: "99.0"),
                                          simulator: Simulator(name: "Example Phone", udid: "X", osVersion: "99.0", platform: "iOS", state: "Shutdown"),
                                          xcodeIsDefault: true)
        return (TestRunner(repository: dir, config: config, environment: environment, xcodebuild: xcodebuild.path), arguments)
    }

    @Test func theOnlySchemeOfAProject() throws {
        var config = SnapshotConfig()
        config.project = "Shop.xcodeproj"
        // xcodebuild can print a warning before the JSON.
        let (runner, arguments) = try runner(listing: "warning: something\n" + #"{"project": {"name": "Shop", "schemes": ["Shop"]}}"#, config: config)
        #expect(try runner.resolveScheme() == "Shop")
        #expect(try String(contentsOf: arguments, encoding: .utf8) == "-list -json -project Shop.xcodeproj\n")
    }

    /// A package lists a scheme per product plus `<Name>-Package`, which tests them all.
    @Test func aPackagesSchemeForAllItsProducts() throws {
        let (runner, _) = try runner(listing: #"{"workspace": {"name": "Kit", "schemes": ["Kit", "KitUI", "Kit-Package"]}}"#)
        #expect(try runner.resolveScheme() == "Kit-Package")
    }

    @Test func severalSchemesAreAQuestionForTheUser() throws {
        let (runner, _) = try runner(listing: #"{"project": {"schemes": ["Shop", "Shop Staging"]}}"#)
        #expect(throws: ConfigError.missingScheme) { try runner.resolveScheme() }
        let (empty, _) = try self.runner(listing: "not json")
        #expect(throws: ConfigError.missingScheme) { try empty.resolveScheme() }
    }

    @Test func aConfiguredSchemeIsNotLookedUp() throws {
        var config = SnapshotConfig()
        config.scheme = "Snapshots"
        let (runner, arguments) = try runner(listing: "{}", config: config)
        #expect(try runner.resolveScheme() == "Snapshots")
        #expect(!FileManager.default.fileExists(atPath: arguments.path))
    }
}

@Suite struct ModulePickerTests {
    /// The picker offers the test targets that have committed snapshots, by their `…Tests` folder.
    @Test func testTargetsWithSnapshots() throws {
        let repo = try TempRepo()
        let red = png(width: 1, height: 1, rgba: (255, 0, 0, 255))
        try repo.write("Tests/ShopTests/Views/__Snapshots__/CardTests/a.1.png", red)
        try repo.write("Modules/Login/Tests/LoginTests/__Snapshots__/FormTests/b.1.png", red)
        try repo.write("Snapshots/__Snapshots__/Loose/c.1.png", red)
        try repo.write("Tests/ShopTests/CardTests.swift", "")
        try repo.commitAll("init")
        #expect(try ProjectContext.load(repository: repo.url).modules() == ["LoginTests", "ShopTests", "Snapshots"])
    }
}
