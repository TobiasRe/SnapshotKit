import Foundation
import Testing
@testable import SnapshotKitCore

@Suite(.isolated) struct MiniYAMLTests {
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

    /// A quoted scalar's escapes are its quotes and backslashes; a `\"` doesn't end it, nor start a comment.
    @Test func quotedScalarsDecodeTheirEscapes() throws {
        let values = try MiniYAML.parse(#"""
        scheme: "My \"App\" # 2"
        device: 'Tobias''s Phone'
        path: "C:\\Apps\u00E9\t."
        onlyTesting: ["A\", B", 'C''s']
        """#)
        #expect(values["scheme"] == .scalar(#"My "App" # 2"#))
        #expect(values["device"] == .scalar("Tobias's Phone"))
        #expect(values["path"] == .scalar("C:\\Appsé\t."))
        #expect(values["onlyTesting"] == .list([#"A", B"#, "C's"]))
        // Not one quoted scalar: as written.
        #expect(MiniYAML.unquote(#""a" "b""#) == #""a" "b""#)
        #expect(MiniYAML.unquote(#""open"#) == #""open"#)
    }

    /// Many editors and linters start a YAML file with `---`.
    @Test func documentMarkersAreNotSettings() throws {
        #expect(try MiniYAML.parse("---\nscheme: App\n...\n") == ["scheme": .scalar("App")])
    }

    @Test func rejectsNestedMappings() {
        #expect(throws: MiniYAML.ParseError.self) { try MiniYAML.parse("a:\n  b: c\n") }
    }
}

@Suite(.isolated) struct ShellWordsTests {
    @Test func splitsQuotes() {
        #expect(ShellWords.split(#"xcodebuild -destination 'platform=iOS Simulator,name=Example Phone' -scheme "My App""#)
                == ["xcodebuild", "-destination", "platform=iOS Simulator,name=Example Phone", "-scheme", "My App"])
    }

    @Test func cutsAtPipesAndAnd() {
        #expect(ShellWords.firstCommand("xcodebuild test -scheme A | xcpretty") == "xcodebuild test -scheme A ")
        #expect(ShellWords.firstCommand("xcodebuild test && echo done") == "xcodebuild test ")
        #expect(ShellWords.firstCommand("xcodebuild test -scheme 'a|b'") == "xcodebuild test -scheme 'a|b'")
        #expect(ShellWords.firstCommand("xcodebuild test -scheme App) && echo done") == "xcodebuild test -scheme App")
        #expect(ShellWords.firstCommand("xcodebuild test -scheme $(scheme)") == "xcodebuild test -scheme $(scheme)")
    }

    /// The commands of a line's start up to a command in a subshell: those in the subshell before it too.
    @Test func commandsBeforeOneInASubshell() {
        #expect(ShellWords.commands("cd a && (cd b) && (cd c && ") == ["cd a"])
        #expect(ShellWords.commands("cd a && (cd b) && (cd c && ", enteringOpenSubshells: true) == ["cd a", "cd c"])
        #expect(ShellWords.commands("x=$(cd b && ", enteringOpenSubshells: true) == ["x=$(cd b &&"])
    }
}

@Suite(.isolated) struct CIConfigParserTests {
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

    /// GitHub Actions: the step's `working-directory`, else the job's `defaults`, else the
    /// workflow's; a `cd` in the step's script goes on from there.
    @Test func githubWorkingDirectories() {
        func workingDirectory(_ job: String) -> String? {
            CIConfigParser.extract(from: [.init(name: "ci.yml", text: """
                defaults:
                  run:
                    working-directory: ./App
                jobs:
                \(job)
                """)]).config.workingDirectory
        }
        #expect(workingDirectory("""
              snapshots:
                steps:
                  - run: xcodebuild test -scheme App
            """) == "App")
        #expect(workingDirectory("""
              snapshots:
                defaults:
                  run:
                    working-directory: ios
                steps:
                  - uses: actions/checkout@v4
                  - name: Snapshots
                    run: xcodebuild test -scheme App
            """) == "ios")
        #expect(workingDirectory("""
              snapshots:
                defaults:
                  run:
                    working-directory: ios
                steps:
                  - name: Snapshots
                    run: |
                      cd Feature
                      xcodebuild test -scheme App
                    working-directory: "${{ github.workspace }}/Modules"
            """) == "Modules/Feature")
        // The workflow's default applies to no other step's `cd`.
        #expect(workingDirectory("""
              snapshots:
                steps:
                  - run: cd Elsewhere
                  - run: xcodebuild test -scheme App
            """) == "App")
    }

    /// GitLab: a `cd` in the job's `before_script`, else the `default:` one, carries on into `script`.
    @Test func gitlabWorkingDirectories() {
        func workingDirectory(_ text: String) -> String? {
            CIConfigParser.extract(from: [.init(name: ".gitlab-ci.yml", text: text)]).config.workingDirectory
        }
        #expect(workingDirectory("""
            snapshots:
              before_script:
                - cd ios
                - bundle install
              script:
                - xcodebuild test -scheme App
            """) == "ios")
        #expect(workingDirectory("""
            default:
              before_script:
                - cd "$CI_PROJECT_DIR/ios"
            snapshots:
              script:
                - cd App && pod install
                - xcodebuild test -scheme App
            """) == "ios/App")
        // Also one written on its key's line.
        #expect(workingDirectory("""
            default:
              before_script: [cd ios, bundle install]
            snapshots:
              script:
                - xcodebuild test -scheme App
            """) == "ios")
        #expect(workingDirectory("""
            snapshots:
              before_script: "cd ios && cd App"
              script: xcodebuild test -scheme App
            """) == "ios/App")
        #expect(workingDirectory("""
            snapshots:
              before_script: &setup
                - cd ios
              script: xcodebuild test -scheme App
            """) == "ios")
        // A job's own before_script replaces the default one.
        #expect(workingDirectory("""
            default:
              before_script:
                - cd ios
            snapshots:
              before_script:
                - echo hello
              script:
                - xcodebuild test -scheme App
            """) == nil)
    }

    /// A job without a `before_script` of its own runs that of the jobs it `extends:`, the later ones
    /// overriding the earlier, before `default:`'s; one merged into it from an anchor is its own.
    @Test func gitlabInheritedBeforeScripts() {
        func workingDirectory(_ text: String, including included: String? = nil) -> String? {
            let documents: [CIConfigParser.Document] = [.init(name: ".gitlab-ci.yml", text: text)]
                + (included.map { [.init(name: "ci/ios.yml", text: $0)] } ?? [])
            return CIConfigParser.extract(from: documents).config.workingDirectory
        }
        let job = """
            snapshots:
              extends: .ios
              script:
                - xcodebuild test -workspace Shop.xcworkspace -scheme Shop
            """
        let template = """
            .ios:
              before_script:
                - cd App
                - bundle install

            """
        #expect(workingDirectory(template + job) == "App")
        #expect(workingDirectory(job, including: template) == "App")
        #expect(workingDirectory("default:\n  before_script:\n    - cd ios\n" + template + job) == "App")
        #expect(workingDirectory("""
            .base:
              before_script:
                - cd ios
            .ios:
              extends: .base
            .lint:
              tags: [macos]
            snapshots:
              extends:
                - .ios
                - .lint
              script: xcodebuild test -scheme Shop
            """) == "ios")
        #expect(workingDirectory("""
            .app:
              before_script:
                - cd App
            .ios:
              before_script:
                - cd ios
            snapshots:
              extends: [.ios, .app]
              script: xcodebuild test -scheme Shop
            """) == "App")
        // The job's own `before_script:` overrides them, even one that doesn't move.
        #expect(workingDirectory(template + job.replacingOccurrences(of: "  script:", with: "  before_script: [echo hi]\n  script:")) == nil)
        // A cycle of `extends:` ends.
        #expect(workingDirectory("""
            .a:
              extends: .b
            .b:
              extends: .a
            snapshots:
              extends: .a
              script: xcodebuild test -scheme Shop
            """) == nil)
        #expect(workingDirectory("""
            .ios: &ios
              before_script:
                - cd App
            .ci: &ci
              before_script:
                - cd ios
            snapshots:
              <<: [*ios, *ci]
              script:
                - xcodebuild test -scheme Shop
            """) == "App")
        #expect(workingDirectory("""
            default:
              before_script:
                - cd ios
            .ios: &ios
              extends: .app
            .app:
              before_script:
                - cd App
            snapshots:
              <<: *ios
              script:
                - xcodebuild test -scheme Shop
            """) == "App")
    }

    /// GitLab's documentation writes a list level with its key: `script:`, then `- cd ios` below it.
    @Test func gitlabListsLevelWithTheirKey() {
        func workingDirectory(_ text: String) -> String? {
            CIConfigParser.extract(from: [.init(name: ".gitlab-ci.yml", text: text)]).config.workingDirectory
        }
        #expect(workingDirectory("""
            snapshots:
              script:
              - cd ios
              - xcodebuild test -scheme App
            """) == "ios")
        #expect(workingDirectory("""
            default:
              before_script:
              - cd ios
            snapshots:
              before_script:
              - cd App
              script:
              - xcodebuild test -scheme App
            """) == "App")
        #expect(workingDirectory("""
            snapshots:
              before_script:
              - cd ios
              script:
              - |
                cd App
                xcodebuild test -scheme App
            """) == "ios/App")
        // Another job's list, level with it, isn't this job's.
        #expect(workingDirectory("""
            lint:
              script:
              - cd docs
            snapshots:
              script:
              - xcodebuild test -scheme App
            """) == nil)
    }

    /// A command can be a quoted YAML scalar; the shell gets it without the quotes.
    @Test func quotedScriptItems() {
        func extract(_ script: String) -> CIConfigParser.Extraction {
            CIConfigParser.extract(from: [.init(name: ".gitlab-ci.yml", text: "snapshots:\n  script:\n" + script)])
        }
        let separate = extract("""
                - 'cd ios'
                - "xcodebuild test -scheme App"
            """)
        #expect(separate.config.workingDirectory == "ios")
        #expect(separate.config.scheme == "App")
        let chained = extract("""
                - "cd ios && xcodebuild test -scheme 'My App'"
            """)
        #expect(chained.config.workingDirectory == "ios")
        #expect(chained.config.scheme == "My App")
        // The shell gets the scalar's value: its escaped quotes are the command's own.
        let doubleQuoted = extract(#"""
                - "xcodebuild test -scheme \"My App\" -destination \"platform=iOS Simulator,name=iPhone 17,OS=26.0\""
            """#)
        #expect(doubleQuoted.invocation?.arguments == ["test", "-scheme", "My App", "-destination", "platform=iOS Simulator,name=iPhone 17,OS=26.0"])
        let singleQuoted = extract("""
                - 'xcodebuild test -scheme ''My App'' -destination ''platform=iOS Simulator,name=iPhone 17'''
            """)
        #expect(singleQuoted.invocation?.arguments == ["test", "-scheme", "My App", "-destination", "platform=iOS Simulator,name=iPhone 17"])
        let escapedFolder = extract(#"""
                - "cd \"ios app\" && xcodebuild test -scheme App"
            """#)
        #expect(escapedFolder.config.workingDirectory == "ios app")
        #expect(escapedFolder.config.scheme == "App")
        // A shell script's own quotes stay.
        #expect(CIConfigParser.extract(from: [.init(name: "scripts/test.sh", text: "#!/bin/bash\n\"cd\" 'ios'\nxcodebuild test -scheme App\n")])
                .config.workingDirectory == "ios")
    }

    @Test func shellScriptWorkingDirectory() {
        let script = "#!/bin/bash\nset -euo pipefail\ncd ios\nif true; then\n  xcodebuild test -scheme App\nfi\n"
        #expect(CIConfigParser.extract(from: [.init(name: "scripts/test.sh", text: script)]).config.workingDirectory == "ios")
    }

    /// Every `cd` of a line's chain of commands counts, in order, on the call's line and those
    /// before it; not a subshell's, nor one in a shell function's body away from the call.
    @Test func workingDirectoriesOfCommandChains() {
        func workingDirectory(_ script: String) -> String? {
            CIConfigParser.extract(from: [.init(name: "scripts/test.sh", text: "#!/bin/bash\n" + script)]).config.workingDirectory
        }
        let test = "xcodebuild test -scheme App\n"
        #expect(workingDirectory("cd ios && pod install && cd ..\n" + test) == nil)
        #expect(workingDirectory("cd ios; " + test) == "ios")
        #expect(workingDirectory("cd ios && pod install && " + test) == "ios")
        #expect(workingDirectory("cd ios && xcodebuild -version && " + test) == "ios")
        #expect(workingDirectory("cd ios || exit 1\n" + test) == "ios")
        #expect(workingDirectory("if [ -d ios ]; then cd ios; fi\n" + test) == "ios")
        #expect(workingDirectory("while ! cd ios; do sleep 1; done\n" + test) == "ios")
        #expect(workingDirectory("pushd ios\n" + test + "popd\n") == "ios")
        #expect(workingDirectory("pushd ios\npopd\n" + test) == nil)
        #expect(workingDirectory("(cd docs && make)\n" + test) == nil)
        #expect(workingDirectory("echo \"$(cd docs && pwd)\"\n" + test) == nil)
        // A function's `cd` runs where it is called; one in the function that makes the call counts.
        #expect(workingDirectory("build_docs() {\n  cd docs\n  make\n}\ncd ios\n" + test) == "ios")
        #expect(workingDirectory("function build_docs\n{\n  cd docs\n}\n" + test) == nil)
        #expect(workingDirectory("main() {\n  cd ios\n  " + test + "}\nmain\n") == "ios")
        // A folder found out only when it runs leads back to the root, where a later `cd` goes on.
        #expect(workingDirectory("cd \"$(dirname \"$0\")/..\"\ncd ios\n" + test) == "ios")
    }

    /// A command run in a subshell runs where the subshell's commands before it lead, and ends
    /// with the subshell; a subshell closed before it still doesn't move its shell.
    @Test func aCommandInASubshell() {
        func invocation(_ script: String) -> CIConfigParser.Invocation? {
            CIConfigParser.extract(from: [.init(name: "scripts/test.sh", text: "#!/bin/bash\n" + script)]).invocation
        }
        let inSubshell = invocation("(cd ios && xcodebuild test -scheme App)\n")
        #expect(inSubshell?.arguments == ["test", "-scheme", "App"])
        #expect(inSubshell?.workingDirectory == "ios")
        #expect(invocation("cd ios && (cd App && xcodebuild test -scheme App) | xcpretty\n")?.workingDirectory == "ios/App")
        #expect(invocation("( (cd docs && make) && cd ios && xcodebuild test -scheme App )\n")?.workingDirectory == "ios")
        #expect(invocation("(cd docs && make) && xcodebuild test -scheme App\n")?.workingDirectory == nil)
        #expect(invocation("cd ios\n( xcodebuild test -scheme App )\n")?.arguments == ["test", "-scheme", "App"])
        #expect(invocation("xcodebuild test -scheme App -destination \"$(destination)\" -only-testing:$(suite)\n")?.arguments
                == ["test", "-scheme", "App", "-destination", "$(destination)", "-only-testing:$(suite)"])
    }

    /// GitLab's `script:` can be the command itself, after a `before_script:` that moves.
    @Test func aGitLabScriptThatIsOneCommand() {
        #expect(CIConfigParser.extract(from: [.init(name: ".gitlab-ci.yml", text: """
            default:
              before_script:
                - cd ios
            snapshots:
              script: cd App && xcodebuild test -scheme App
            """)]).config.workingDirectory == "ios/App")
    }

    @Test func workingDirectoriesFollowEachOther() {
        #expect(CIConfigParser.path(following: [.cd("ios"), .cd("./App")]) == "ios/App")
        #expect(CIConfigParser.path(following: [.cd("ios"), .cd("..")]) == nil)
        #expect(CIConfigParser.path(following: [.cd("ios"), .cd("../Modules")]) == "Modules")
        #expect(CIConfigParser.path(following: [.cd("ios"), .cd("$CI_PROJECT_DIR/Modules")]) == "Modules")
        // Out of the repository, or out of sight: back at the root, as far as can be told.
        #expect(CIConfigParser.path(following: [.cd("..")]) == nil)
        #expect(CIConfigParser.path(following: [.cd("/Users/ci/build")]) == nil)
        #expect(CIConfigParser.path(following: [.cd("$BUILD_DIR")]) == nil)
        #expect(CIConfigParser.path(following: [.cd("$BUILD_DIR"), .cd("ios")]) == "ios")
        #expect(CIConfigParser.path(following: [.cd("ios"), .cd("-")]) == nil)
        // `popd` goes back to where its `pushd` was.
        #expect(CIConfigParser.path(following: [.pushd("ios"), .pushd("App"), .popd]) == "ios")
        #expect(CIConfigParser.path(following: [.cd("ios"), .pushd("App"), .cd("Sources"), .popd]) == "ios")
        #expect(CIConfigParser.path(following: [.cd("ios"), .popd]) == nil)
    }

    /// A function's body runs where the function is called: the `cd`s before its first call count,
    /// then those of the body before the line.
    @Test func workingDirectoriesInShellFunctions() {
        func workingDirectory(_ script: String) -> String? {
            CIConfigParser.extract(from: [.init(name: "scripts/test.sh", text: "#!/bin/bash\n" + script)]).config.workingDirectory
        }
        #expect(workingDirectory("run_tests() {\n  xcodebuild test -scheme App\n}\ncd ios\nrun_tests\n") == "ios")
        #expect(workingDirectory("run_tests() {\n  cd App\n  xcodebuild test -scheme App\n}\ncd ios\nrun_tests\ncd ..\n") == "ios/App")
        #expect(workingDirectory("build() { cd ios && xcodebuild test -scheme App; }\nbuild\n") == "ios")
        #expect(workingDirectory("build() { xcodebuild test -scheme App; }\ncd ios && build\n") == "ios")
        #expect(workingDirectory("build() { xcodebuild test -scheme App; }\nif true; then cd ios && build; fi\n") == "ios")
        // Called from another function, called in its turn.
        #expect(workingDirectory("run_tests() {\n  xcodebuild test -scheme App\n}\nmain() {\n  cd App\n  run_tests\n}\ncd ios\nmain\n") == "ios/App")
        // In a GitHub `run:` block too.
        #expect(CIConfigParser.extract(from: [.init(name: ".github/workflows/snapshots.yml", text: """
            jobs:
              snapshots:
                steps:
                  - run: |
                      run_tests() {
                        xcodebuild test -scheme App
                      }
                      pushd ios
                      pushd App
                      popd
                      run_tests
            """)]).config.workingDirectory == "ios")
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

    @Test func matrixBlockListsUseTheirFirstValue() {
        let text = """
        jobs:
          snapshots:
            strategy:
              matrix:
                xcode:
                  - '99.3'
                  - '99.4'
                device: [Example Phone, Other Phone]
            steps:
              - uses: maxim-lobanov/setup-xcode@v1
                with:
                  xcode-version: ${{ matrix.xcode }}
              - run: xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=${{ matrix.device }}'
        """
        let x = CIConfigParser.extract(from: [.init(name: "ci.yml", text: text)])
        #expect(x.config.xcodeVersion == "99.3")
        #expect(x.config.deviceName == "Example Phone")
    }

    @Test func aShellAssignmentEndsAtTheFirstWord() {
        let script = "#!/bin/sh\nSCHEME=Snapshots xcodebuild test -scheme \"$SCHEME\" -destination 'platform=iOS Simulator,name=Example Phone'\n"
        let x = CIConfigParser.extract(from: [.init(name: "scripts/snapshots.sh", text: script)])
        #expect(x.config.scheme == "Snapshots")
    }

    @Test func aFoldedCommandGoesOnPastItsActionOnALineOfItsOwn() {
        let text = """
        snapshots:
          script:
            - >
              xcodebuild
              -workspace App.xcworkspace
              test
              -scheme Snapshots
        """
        let x = CIConfigParser.extract(from: [.init(name: ".gitlab-ci.yml", text: text)])
        #expect(x.invocation?.actions == ["test"])
        #expect(x.config.scheme == "Snapshots")
    }

    /// GitHub replaces `${{ … }}` before the shell splits the line, so its spaces don't split words.
    @Test func unquotedGitHubExpressionsAreOneWord() {
        let text = """
        env:
          APP_NAME: Shop
        jobs:
          snapshots:
            steps:
              - run: xcodebuild test -scheme ${{ env.APP_NAME }} -testPlan ${{ matrix.plan }} -destination 'platform=iOS Simulator,name=Example Phone'
        """
        let x = CIConfigParser.extract(from: [.init(name: ".github/workflows/snapshots.yml", text: text)])
        #expect(x.config.scheme == "Shop")
        #expect(x.config.testPlan == nil) // `matrix.plan` isn't defined: unknown, not "${{"
        #expect(x.config.deviceName == "Example Phone")
    }

    /// So are those a `cd` goes to.
    @Test func gitHubExpressionsInACdAreOneFolder() {
        func workingDirectory(_ cd: String) -> String? {
            CIConfigParser.extract(from: [.init(name: ".github/workflows/snapshots.yml", text: """
                env:
                  APP_DIR: ios
                jobs:
                  snapshots:
                    steps:
                      - run: |
                          \(cd)
                          xcodebuild test -scheme App
                """)]).config.workingDirectory
        }
        #expect(workingDirectory("cd ${{ env.APP_DIR }}") == "ios")
        #expect(workingDirectory("cd ${{ github.workspace }}/ios") == "ios")
        #expect(workingDirectory("cd ${{ env.APP_DIR }}/App && pod install") == "ios/App")
        #expect(workingDirectory("cd ${{ inputs.folder }}") == nil)
    }

    @Test func everyXcodebuildOnALineCountsAndAFullPathToo() {
        let text = """
        snapshots:
          script:
            - xcodebuild -version && xcodebuild test -scheme Snapshots -destination 'platform=iOS Simulator,name=Example Phone'
        """
        #expect(CIConfigParser.extract(from: [.init(name: ".gitlab-ci.yml", text: text)]).config.scheme == "Snapshots")
        let script = "set -e\n/usr/bin/xcodebuild test -scheme Snapshots -destination 'platform=iOS Simulator,name=Example Phone'\n"
        #expect(CIConfigParser.extract(from: [.init(name: "scripts/snapshots.sh", text: script)]).config.scheme == "Snapshots")
    }

    @Test func commentedOutCommandsAreIgnored() {
        let text = """
        snapshots:
          # image: macos-xcode:98.0
          image: macos-xcode:99.1
          script:
            # - xcodebuild test -scheme OldSnapshots -destination 'platform=iOS Simulator,name=Old Phone'
            - xcodebuild test -scheme Snapshots -destination 'platform=iOS Simulator,name=Example Phone'
        """
        let x = CIConfigParser.extract(from: [.init(name: ".gitlab-ci.yml", text: text)])
        #expect(x.config.scheme == "Snapshots")
        #expect(x.config.deviceName == "Example Phone")
        #expect(x.config.xcodeVersion == "99.1")
    }

    @Test func githubInlineBranchList() {
        let p = CIConfigParser()
        #expect(p.baseBranch(in: "on:\n  pull_request:\n    branches: [ 'feature/*', trunk ]\n") == "trunk")
    }

    @Test func referencedScripts() {
        #expect(CIConfigParser.referencedScripts(in: "script:\n  - ./scripts/snapshots.sh --ci\n  - bash ci/other.sh") == ["scripts/snapshots.sh", "ci/other.sh"])
    }
}

@Suite(.isolated) struct ConfigResolverTests {
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
        #expect(resolved.notes == ["Ignored unknown keys in .snapshotkit.yml: typo"])
    }

    @Test func listsWhereOneValueBelongsAreReported() throws {
        let (config, unknown, mistyped) = try SnapshotConfig.fromOverrideFile("scheme: [A, B]\nonlyTesting: AppTests\ndevice: Phone\n")
        #expect(config.scheme == nil && config.source(of: .scheme) == nil)
        #expect(config.onlyTesting == ["AppTests"])
        #expect(config.deviceName == "Phone")
        #expect(unknown.isEmpty)
        #expect(mistyped == ["scheme"])
    }

    @Test func xcodeComesFromTheDocumentWithTheTestCommand() {
        let documents = [
            CIConfigParser.Document(name: "a.yml", text: "env:\n  XCODE_VERSION: 98.0\n"),
            CIConfigParser.Document(name: "b.yml", text: "env:\n  XCODE_VERSION: 98.1\n"),
            CIConfigParser.Document(name: "c.yml", text: "XCODE_VERSION: 99.0\nrun: xcodebuild test -scheme Snapshots\n"),
            CIConfigParser.Document(name: "d.yml", text: "env:\n  XCODE_VERSION: 98.2\n"),
        ]
        let config = CIConfigParser.extract(from: documents).config
        #expect(config.xcodeVersion == "99.0")
        #expect(config.source(of: .xcodeVersion) == "c.yml")
    }

    @Test func baseBranchAutoDetection() throws {
        let repo = try TempRepo(branch: "main")
        try repo.write("README", "x")
        try repo.commitAll("init")
        let resolved = try ConfigResolver.resolve(repository: repo.url)
        #expect(resolved.config.baseBranch == "main")
        #expect(resolved.config.source(of: .baseBranch) == "git (auto-detected)")
    }

    /// The branch `origin/HEAD` names comes first: here a `trunk`, though `main` exists too.
    @Test func baseBranchFromOriginHEAD() throws {
        let repo = try TempRepo(branch: "main")
        try repo.write("README", "x")
        try repo.commitAll("init")
        try repo.git.run(["branch", "trunk"])
        for branch in ["main", "trunk"] { try repo.git.run(["update-ref", "refs/remotes/origin/\(branch)", "HEAD"]) }
        try repo.git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"])
        let resolved = try ConfigResolver.resolve(repository: repo.url)
        #expect(resolved.config.baseBranch == "trunk")
        #expect(resolved.config.source(of: .baseBranch) == "git (auto-detected)")
    }
}

@Suite(.isolated) struct EnvironmentValidatorTests {
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

    @Test func versionOrderAndRuntimeNames() throws {
        #expect(EnvironmentValidator.compareVersions("99.10", "99.9") == .orderedDescending)
        #expect(EnvironmentValidator.compareVersions("99.1", "99.1") == .orderedSame)
        #expect(EnvironmentValidator.compareVersions("9.4", "10.0") == .orderedAscending)
        let iOS = try #require(EnvironmentValidator.parseRuntime("com.apple.CoreSimulator.SimRuntime.iOS-99-1"))
        #expect(iOS == ("iOS", "99.1"))
        let vision = try #require(EnvironmentValidator.parseRuntime("com.apple.CoreSimulator.SimRuntime.xrOS-2-0"))
        #expect(vision == ("visionOS", "2.0"))
        #expect(EnvironmentValidator.parseRuntime("com.apple.CoreSimulator.SimRuntime.unknown") == nil)
    }

    /// A `developerDir` in `~/` is in the home folder of the Mac it runs on.
    @Test func aDeveloperDirInTheHomeFolder() throws {
        let xcode = XcodeInstall(path: "/Users/me/Applications/Xcode-98.0.app", version: "98.0")
        var config = SnapshotConfig()
        config.developerDir = "~/Applications/Xcode-98.0.app/Contents/Developer"
        let (picked, _) = try EnvironmentValidator.selectXcode(for: config, installed: installs, selected: nil, home: "/Users/me",
                                                               lookup: { $0 == xcode.path ? xcode : nil })
        #expect(picked == xcode)
        #expect(throws: EnvironmentError.xcodePathMissing("/Users/someone/Applications/Xcode-98.0.app")) {
            try EnvironmentValidator.selectXcode(for: config, installed: installs, selected: nil, home: "/Users/someone",
                                                 lookup: { $0 == xcode.path ? xcode : nil })
        }
    }

    @Test func selectsPinnedXcodeOrExplainsWhatIsMissing() throws {
        var config = SnapshotConfig()
        config.xcodeVersion = "99.1"
        let (picked, isDefault) = try EnvironmentValidator.selectXcode(for: config, installed: installs, selected: installs[0], home: "/Users/me", lookup: { _ in nil })
        #expect(picked.version == "99.1")
        #expect(!isDefault)

        config.xcodeVersion = "98.0"
        config.sources["xcode"] = ".gitlab-ci.yml"
        let error = try #require(throws: EnvironmentError.self) {
            try EnvironmentValidator.selectXcode(for: config, installed: installs, selected: nil, home: "/Users/me", lookup: { _ in nil })
        }
        #expect(error == .xcodeNotInstalled(required: "98.0", source: ".gitlab-ci.yml", installed: installs))
        #expect(error.errorDescription == "Xcode 98.0 is not installed (required by `.gitlab-ci.yml`). Installed: 99.2 at `/Apps/Xcode-99.2.app`, "
                + "99.1 at `/Apps/Xcode-99.1.app`. Install it (e.g. from developer.apple.com/download or with `xcodes install 98.0`), or set `xcode:` in `.snapshotkit.yml`.")
    }

    /// `developerDir` names one Xcode: it is the one used, though a version is pinned too, which
    /// the note says when that Xcode is another version. It used to take the newest 99.1.x instead.
    @Test func developerDirWinsOverAPinnedVersionAndSaysSo() throws {
        let older = XcodeInstall(path: "/Apps/Xcode-98.0.app", version: "98.0")
        var config = SnapshotConfig()
        config.developerDir = older.developerDir
        config.xcodeVersion = "99.1"
        config.sources = ["developerDir": ".snapshotkit.yml", "xcode": ".gitlab-ci.yml"]
        let (picked, isDefault) = try EnvironmentValidator.selectXcode(for: config, installed: installs + [older], selected: installs[0],
                                                                       home: "/Users/me", lookup: { $0 == older.path ? older : nil })
        #expect(picked == older)
        #expect(!isDefault)
        #expect(EnvironmentValidator.notes(for: config, xcode: picked) == [
            "Using Xcode 98.0 at `/Apps/Xcode-98.0.app` (`developerDir`, from .snapshotkit.yml), not Xcode 99.1 as pinned by .gitlab-ci.yml: "
                + "snapshots may differ from CI’s.",
        ])
        // The version it is: nothing to say.
        config.xcodeVersion = "98"
        #expect(EnvironmentValidator.notes(for: config, xcode: picked).isEmpty)
    }

    @Test func unpinnedUsesSelectedXcode() throws {
        let (picked, isDefault) = try EnvironmentValidator.selectXcode(for: SnapshotConfig(), installed: installs, selected: installs[1], home: "/Users/me", lookup: { _ in nil })
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

    /// Snapshots differ between OS versions: a booted simulator only wins on the runtime asked for.
    @Test func latestIsTheNewestRuntimeEvenWhenAnOlderOneIsBooted() throws {
        let sims = try EnvironmentValidator.parseSimulators(Data("""
            {"devices": {
              "com.apple.CoreSimulator.SimRuntime.iOS-99-0": [{"name": "Example Phone", "udid": "NEW", "state": "Shutdown"}],
              "com.apple.CoreSimulator.SimRuntime.iOS-98-4": [{"name": "Example Phone", "udid": "OLD", "state": "Booted"}]
            }}
            """.utf8))
        var config = SnapshotConfig()
        config.deviceName = "Example Phone"
        for os in [nil, "latest"] {
            config.osVersion = os
            #expect(try EnvironmentValidator.selectSimulator(for: config, from: sims, xcode: installs[0]).udid == "NEW")
        }
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
