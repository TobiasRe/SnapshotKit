import Foundation
import Testing
@testable import SnapshotKitCore

/// CI files, then `.snapshotkit.yml`, then the app's per-project settings, from the files in a
/// repository to the `xcodebuild` command line, with where each value came from.
@Suite(.isolated) struct ConfigPrecedenceTests {
    func makeRepo() throws -> TempRepo {
        let repo = try TempRepo()
        try repo.write(".gitlab-ci.yml", """
            include:
              - local: ci/snapshots.yml
            variables:
              XCODE_VERSION: "99.1"
            """)
        try repo.write("ci/snapshots.yml", """
            snapshot-tests:
              rules:
                - if: '$CI_MERGE_REQUEST_TARGET_BRANCH_NAME == "develop"'
              script:
                - xcodebuild test -workspace App.xcworkspace -scheme App -testPlan Snapshots
                  -destination "platform=iOS Simulator,name=Example Phone,OS=99.0" -only-testing:AppSnapshotTests
            """)
        try repo.write(".snapshotkit.yml", """
            device: Other Phone
            onlyTesting: []
            remoteHost: ci-mac
            extraArguments: -configuration Debug
            """)
        try repo.commitAll("init")
        return repo
    }

    func values(_ config: SnapshotConfig) -> [String: String] {
        var values: [String: String] = [:]
        func add(_ field: SnapshotConfig.Field, _ value: String?) {
            values[field.rawValue] = (value ?? "nil") + " (" + (config.source(of: field) ?? "no source") + ")"
        }
        add(.xcodeVersion, config.xcodeVersion)
        add(.deviceName, config.deviceName)
        add(.osVersion, config.osVersion)
        add(.scheme, config.scheme)
        add(.workspace, config.workspace)
        add(.testPlan, config.testPlan)
        add(.onlyTesting, config.onlyTesting.joined(separator: ","))
        add(.baseBranch, config.baseBranch)
        add(.remoteHost, config.remoteHost)
        add(.extraArguments, config.extraArguments.joined(separator: " "))
        return values
    }

    @Test func theOverrideFileWinsOverCIAndCanClearAList() throws {
        let repo = try makeRepo()
        let context = try ProjectContext.load(repository: repo.url)
        #expect(context.resolved.ciFiles == [".gitlab-ci.yml", "ci/snapshots.yml"])
        #expect(context.resolved.overrideFile == ".snapshotkit.yml")
        #expect(context.resolved.notes.isEmpty)
        #expect(values(context.config) == [
            "xcode": "99.1 (.gitlab-ci.yml)",
            "device": "Other Phone (.snapshotkit.yml)",
            "os": "99.0 (ci/snapshots.yml)",
            "scheme": "App (ci/snapshots.yml)",
            "workspace": "App.xcworkspace (ci/snapshots.yml)",
            "testPlan": "Snapshots (ci/snapshots.yml)",
            "onlyTesting": " (.snapshotkit.yml)",
            "baseBranch": "develop (ci/snapshots.yml)",
            "remoteHost": "ci-mac (.snapshotkit.yml)",
            "extraArguments": "-configuration Debug (.snapshotkit.yml)",
        ])
    }

    @Test func projectSettingsWinOverBoth() throws {
        let repo = try makeRepo()
        let settings = ProjectSettings(baseBranch: "trunk", remoteHost: "my-mac", module: "AppSnapshotTests")
        let config = try ProjectContext.load(repository: repo.url, settings: settings).config
        let resolved = values(config)
        #expect(resolved["baseBranch"] == "trunk (project setting)")
        #expect(resolved["remoteHost"] == "my-mac (project setting)")
        #expect(resolved["onlyTesting"] == "AppSnapshotTests (module picker)")
        #expect(resolved["device"] == "Other Phone (.snapshotkit.yml)")
        #expect(TestRunner.arguments(config: config, scheme: config.scheme!, destination: "id=X", resultBundlePath: "/r.xcresult",
                                     onlyTesting: nil, additional: [])
                == ["test", "-workspace", "App.xcworkspace", "-scheme", "App", "-testPlan", "Snapshots", "-destination", "id=X",
                    "-resultBundlePath", "/r.xcresult", "-only-testing:AppSnapshotTests", "-configuration", "Debug",
                    "-collect-test-diagnostics", "never"])
    }

    /// An empty setting (a cleared field in the app) is no setting.
    @Test func emptyProjectSettingsDontOverride() throws {
        let repo = try makeRepo()
        let config = try ProjectContext.load(repository: repo.url, settings: ProjectSettings(baseBranch: "", remoteHost: "", module: "")).config
        #expect(values(config) == values(try ProjectContext.load(repository: repo.url).config))
    }

    /// Without CI files the override file is all there is, and the one project in the repository is found.
    @Test func withoutCIFiles() throws {
        let repo = try TempRepo(branch: "main")
        try repo.write("Shop.xcodeproj/project.pbxproj", "")
        try repo.write(".snapshotkit.yml", "scheme: Shop\nos: latest\n")
        try repo.commitAll("init")
        let resolved = try ConfigResolver.resolve(repository: repo.url)
        #expect(resolved.ciFiles.isEmpty)
        #expect(resolved.notes == ["No .gitlab-ci.yml or .github/workflows found; using .snapshotkit.yml only."])
        #expect(values(resolved.config)["scheme"] == "Shop (.snapshotkit.yml)")
        #expect(values(resolved.config)["os"] == "latest (.snapshotkit.yml)")
        #expect(resolved.config.project == "Shop.xcodeproj" && resolved.config.source(of: .project) == "found in repository")
        #expect(values(resolved.config)["baseBranch"] == "main (git (auto-detected))")
    }
}
