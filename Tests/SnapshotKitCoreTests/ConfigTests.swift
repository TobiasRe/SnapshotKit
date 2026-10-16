import Foundation
import Testing
@testable import SnapshotKitCore

@Suite struct MiniYAMLTests {
    @Test func scalarsListsAndComments() throws {
        let values = try MiniYAML.parse("""
        # comment
        xcode: "99.1"   # pinned
        device: Example Phone
        onlyTesting: [FeatureSnapshotTests, 'Other Tests']
        skipTesting:
          - Slow
          - "Flaky # not a comment"
        """)
        #expect(values["xcode"] == .scalar("99.1"))
        #expect(values["device"] == .scalar("Example Phone"))
        #expect(values["onlyTesting"] == .list(["FeatureSnapshotTests", "Other Tests"]))
        #expect(values["skipTesting"] == .list(["Slow", "Flaky # not a comment"]))
    }

    @Test func rejectsNestedMappings() {
        #expect(throws: MiniYAML.ParseError.self) { try MiniYAML.parse("a:\n  b: c\n") }
    }
}

@Suite struct ShellWordsTests {
    @Test func splitsQuotes() {
        #expect(ShellWords.split(#"xcodebuild -destination 'platform=iOS Simulator,name=Example Phone' -scheme "My App""#)
                == ["xcodebuild", "-destination", "platform=iOS Simulator,name=Example Phone", "-scheme", "My App"])
    }

    @Test func cutsAtPipesAndAnd() {
        #expect(ShellWords.firstCommand("xcodebuild test -scheme A | xcpretty") == "xcodebuild test -scheme A ")
        #expect(ShellWords.firstCommand("xcodebuild test && echo done") == "xcodebuild test ")
        #expect(ShellWords.firstCommand("xcodebuild test -scheme 'a|b'") == "xcodebuild test -scheme 'a|b'")
    }
}

@Suite struct CIConfigParserTests {
    static let gitlab = """
    variables:
      XCODE_VERSION: "99.1"
      SIM_NAME: "Example Phone"
      DESTINATION: "platform=iOS Simulator,name=${SIM_NAME},OS=99.0"

    unit-tests:
      script:
        - xcodebuild test -workspace App.xcworkspace -scheme App -destination "$DESTINATION" -only-testing:AppTests

    snapshot-tests:
      stage: test
      image: registry.example.com/macos-xcode:${XCODE_VERSION}
      rules:
        - if: '$CI_MERGE_REQUEST_TARGET_BRANCH_NAME == "develop"'
      script:
        - set -o pipefail
        - xcodebuild test
          -workspace App.xcworkspace
          -scheme App
          -testPlan Snapshots
          -destination "$DESTINATION"
          -only-testing:AppSnapshotTests 2>&1 | xcbeautify
    """

    static let github = """
    name: Snapshots
    on:
      pull_request:
        branches:
          - main
          - 'release/**'
    env:
      DEVELOPER_DIR: /Applications/Xcode_99.2.app/Contents/Developer
    jobs:
      snapshots:
        runs-on: macos-latest
        steps:
          - uses: actions/checkout@v4
          - name: Run snapshot tests
            run: |
              cd Modules/Feature && xcodebuild test \\
                -scheme Feature \\
                -destination 'platform=iOS Simulator,name=Example Phone,OS=latest' \\
                -resultBundlePath out.xcresult
    """

    @Test func gitlabPicksSnapshotJobAndExpandsVariables() {
        let x = CIConfigParser.extract(from: [.init(name: ".gitlab-ci.yml", text: Self.gitlab)])
        #expect(x.config.workspace == "App.xcworkspace")
        #expect(x.config.scheme == "App")
        #expect(x.config.testPlan == "Snapshots")
        #expect(x.config.onlyTesting == ["AppSnapshotTests"])
        #expect(x.config.deviceName == "Example Phone")
        #expect(x.config.osVersion == "99.0")
        #expect(x.config.platform == "iOS Simulator")
        #expect(x.config.xcodeVersion == "99.1")
        #expect(x.config.baseBranch == "develop")
        #expect(x.config.source(of: .scheme) == ".gitlab-ci.yml")
    }

    @Test func githubBackslashContinuationsCdAndDeveloperDir() {
        let x = CIConfigParser.extract(from: [.init(name: ".github/workflows/snapshots.yml", text: Self.github)])
        #expect(x.config.scheme == "Feature")
        #expect(x.config.workingDirectory == "Modules/Feature")
        #expect(x.config.deviceName == "Example Phone")
        #expect(x.config.osVersion == "latest")
        #expect(x.config.xcodeVersion == "99.2")
        #expect(x.config.baseBranch == "main")
    }

    @Test func xcodeSelectionVariants() {
        let p = CIConfigParser()
        #expect(p.xcodeSelection(in: "- uses: maxim-lobanov/setup-xcode@v1\n  with:\n    xcode-version: '98.4'").version == "98.4")
        #expect(p.xcodeSelection(in: "sudo xcode-select -s /Applications/Xcode-97.0.1.app").version == "97.0.1")
        #expect(p.xcodeSelection(in: "xcodes select 96.3").version == "96.3")
        #expect(p.xcodeSelection(in: "sudo xcode-select -s /Applications/Xcode.app").developerDir == "/Applications/Xcode.app")
    }

    /// The test job lives in a template from another project; only variables are local.
    static let templated = """
    include:
        - project: 'group/ios/ci-templates'
          ref: 'develop'
          file: 'module.yml'

    variables:
        XCODE_PROJECT: "feature-example.xcodeproj"
        PROJECT_PATH: "$UNDEFINED_DIR/$XCODE_PROJECT"
        SCHEME: "feature-example"
        SNAPSHOT_TEST_SCHEME: "FeatureSnapshotTests"
        XCODE_VERSION: "Xcode-99.5.0"
        XCODE_VERSION_FOR_TESTS: $XCODE_VERSION
        SIMULATOR_DEVICE: "Example Phone (99.0.0)"
    """

    @Test func settingsFromVariablesWhenTheJobIsInARemoteTemplate() {
        let x = CIConfigParser.extract(from: [.init(name: ".gitlab-ci.yml", text: Self.templated)])
        #expect(x.invocation == nil)
        #expect(x.config.scheme == "FeatureSnapshotTests")
        #expect(x.config.project == "feature-example.xcodeproj")
        #expect(x.config.xcodeVersion == "99.5.0")
        #expect(x.config.deviceName == "Example Phone")
        #expect(x.config.osVersion == "99.0.0")
        #expect(x.config.source(of: .scheme) == ".gitlab-ci.yml · SNAPSHOT_TEST_SCHEME")
        #expect(x.notes.count == 1)
        #expect(x.notes[0].contains("group/ios/ci-templates (module.yml)"))
    }

    @Test func deviceVariableForms() {
        let parser = CIConfigParser(variables: [:])
        func device(_ value: String) -> [String] {
            parser.variableSettings(["SIMULATOR": value]).map { "\($0.0.rawValue)=\($0.1)" }
        }
        #expect(device("platform=iOS Simulator,name=Example Phone,OS=99.1") == ["device=Example Phone", "os=99.1"])
        #expect(device("Example Phone,OS=99.1") == ["device=Example Phone", "os=99.1"])
        #expect(device("iPhone Example") == ["device=iPhone Example"])
        #expect(device("something else").isEmpty)
        #expect(parser.variableSettings(["IOS_VERSION": "99.2"]).map(\.1) == ["99.2"])
        #expect(parser.variableSettings(["TEST_SCHEME": "A", "SCHEME": "B"]).map(\.1) == ["A"])
    }

    @Test func theCommandLineWinsOverVariables() {
        let text = Self.templated + """

        snapshots:
          script:
            - xcodebuild test -project Other.xcodeproj -scheme OtherSnapshots -destination 'platform=iOS Simulator,name=Other Phone,OS=98.0'
        """
        let x = CIConfigParser.extract(from: [.init(name: ".gitlab-ci.yml", text: text)])
        #expect(x.config.scheme == "OtherSnapshots")
        #expect(x.config.project == "Other.xcodeproj")
        #expect(x.config.deviceName == "Other Phone")
        #expect(x.config.osVersion == "98.0")
        #expect(x.notes.isEmpty)
    }

    @Test func githubInlineBranchList() {
        let p = CIConfigParser()
        #expect(p.baseBranch(in: "on:\n  pull_request:\n    branches: [ 'feature/*', trunk ]\n") == "trunk")
    }

    @Test func referencedScripts() {
        #expect(CIConfigParser.referencedScripts(in: "script:\n  - ./scripts/snapshots.sh --ci\n  - bash ci/other.sh") == ["scripts/snapshots.sh", "ci/other.sh"])
    }
}

@Suite struct ConfigResolverTests {
    @Test func overrideFileWinsAndScriptsAreFollowed() throws {
        let repo = try TempRepo()
        try repo.write(".gitlab-ci.yml", """
        variables:
          XCODE_VERSION: "99.1"
        snapshots:
          script:
            - ./ci/snapshots.sh
        """)
        try repo.write("ci/snapshots.sh", """
        #!/bin/sh
        xcodebuild test -project App.xcodeproj -scheme App -destination "platform=iOS Simulator,name=Example Phone,OS=99.0"
        """)
        try repo.write(".snapshotkit.yml", "device: Other Phone\nbaseBranch: trunk\ntypo: 1\n")
        try repo.commitAll("init")

        let resolved = try ConfigResolver.resolve(repository: repo.url)
        #expect(resolved.config.scheme == "App")
        #expect(resolved.config.project == "App.xcodeproj")
        #expect(resolved.config.source(of: .scheme) == "ci/snapshots.sh")
        #expect(resolved.config.deviceName == "Other Phone")
        #expect(resolved.config.source(of: .deviceName) == ".snapshotkit.yml")
        #expect(resolved.config.osVersion == "99.0")
        #expect(resolved.config.xcodeVersion == "99.1")
        #expect(resolved.config.baseBranch == "trunk")
        #expect(resolved.notes.contains { $0.contains("typo") })
    }

    @Test func baseBranchAutoDetection() throws {
        let repo = try TempRepo(branch: "main")
        try repo.write("README", "x")
        try repo.commitAll("init")
        let resolved = try ConfigResolver.resolve(repository: repo.url)
        #expect(resolved.config.baseBranch == "main")
        #expect(resolved.config.source(of: .baseBranch) == "git (auto-detected)")
    }
}

@Suite struct EnvironmentValidatorTests {
    let installs = [
        XcodeInstall(path: "/Apps/Xcode-99.2.app", version: "99.2"),
        XcodeInstall(path: "/Apps/Xcode-99.1.app", version: "99.1"),
    ]

    @Test func versionMatching() {
        #expect(EnvironmentValidator.versionMatches(installed: "99.1", required: "99.1"))
        #expect(EnvironmentValidator.versionMatches(installed: "99.1.0", required: "99.1"))
        #expect(EnvironmentValidator.versionMatches(installed: "99.1", required: "99"))
        #expect(!EnvironmentValidator.versionMatches(installed: "99.10", required: "99.1"))
    }

    @Test func selectsPinnedXcodeOrExplainsWhatIsMissing() throws {
        var config = SnapshotConfig()
        config.xcodeVersion = "99.1"
        let (picked, isDefault) = try EnvironmentValidator.selectXcode(for: config, installed: installs, selected: installs[0], lookup: { _ in nil })
        #expect(picked.version == "99.1")
        #expect(!isDefault)

        config.xcodeVersion = "98.0"
        config.sources["xcode"] = ".gitlab-ci.yml"
        do {
            _ = try EnvironmentValidator.selectXcode(for: config, installed: installs, selected: nil, lookup: { _ in nil })
            Issue.record("expected an error")
        } catch let error as EnvironmentError {
            let message = error.localizedDescription
            #expect(message.contains("Xcode 98.0 is not installed (required by .gitlab-ci.yml)"))
            #expect(message.contains("99.2 at /Apps/Xcode-99.2.app"))
        }
    }

    @Test func unpinnedUsesSelectedXcode() throws {
        let (picked, isDefault) = try EnvironmentValidator.selectXcode(for: SnapshotConfig(), installed: installs, selected: installs[1], lookup: { _ in nil })
        #expect(picked == installs[1])
        #expect(isDefault)
    }

    static let simctl = """
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-99-0": [
        {"name": "Example Phone", "udid": "A", "state": "Shutdown", "isAvailable": true},
        {"name": "Example Phone", "udid": "B", "state": "Booted", "isAvailable": true},
        {"name": "Example Tablet", "udid": "C", "state": "Shutdown", "isAvailable": true}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-98-4": [
        {"name": "Example Phone", "udid": "D", "state": "Shutdown", "isAvailable": true}
      ],
      "com.apple.CoreSimulator.SimRuntime.tvOS-99-0": [
        {"name": "Example TV", "udid": "E", "state": "Shutdown", "isAvailable": true}
      ]
    }}
    """

    @Test func simulatorSelection() throws {
        let sims = try EnvironmentValidator.parseSimulators(Data(Self.simctl.utf8))
        var config = SnapshotConfig()
        config.deviceName = "Example Phone"
        config.osVersion = "99.0"
        #expect(try EnvironmentValidator.selectSimulator(for: config, from: sims, xcode: installs[0]).udid == "B")
        config.osVersion = "98.4"
        #expect(try EnvironmentValidator.selectSimulator(for: config, from: sims, xcode: installs[0]).udid == "D")
        config.osVersion = "latest"
        #expect(try EnvironmentValidator.selectSimulator(for: config, from: sims, xcode: installs[0]).osVersion == "99.0")
    }

    @Test func simulatorErrorsAreSpecific() throws {
        let sims = try EnvironmentValidator.parseSimulators(Data(Self.simctl.utf8))
        var config = SnapshotConfig()
        config.deviceName = "Missing Phone"
        config.osVersion = "99.0"
        #expect(throws: EnvironmentError.simulatorMissing(name: "Missing Phone", platform: "iOS", os: "99.0", available: ["Example Phone", "Example Tablet"])) {
            try EnvironmentValidator.selectSimulator(for: config, from: sims, xcode: installs[0])
        }
        config.deviceName = "Example Phone"
        config.osVersion = "97.0"
        #expect(throws: EnvironmentError.runtimeMissing(platform: "iOS", os: "97.0", installed: ["iOS 99.0", "iOS 98.4"], xcode: "99.2")) {
            try EnvironmentValidator.selectSimulator(for: config, from: sims, xcode: installs[0])
        }
        #expect(throws: EnvironmentError.self) {
            try EnvironmentValidator.selectSimulator(for: SnapshotConfig(), from: sims, xcode: installs[0])
        }
    }
}
