import Foundation

/// Everything needed to run a project's snapshot tests the way CI does.
/// All fields are optional at this level; `ConfigResolver` fills them from CI files
/// and `.snapshotkit.yml`, and `EnvironmentValidator` checks they are usable.
public struct SnapshotConfig: Codable, Equatable, Sendable {
    public var xcodeVersion: String?
    /// Explicit Xcode location (an `.app` or its `Contents/Developer`), if CI pins a path.
    public var developerDir: String?
    public var platform: String?
    public var deviceName: String?
    public var osVersion: String?
    public var scheme: String?
    public var project: String?
    public var workspace: String?
    public var testPlan: String?
    public var onlyTesting: [String] = []
    public var skipTesting: [String] = []
    public var baseBranch: String?
    /// Directory (relative to the repo root) to run xcodebuild from.
    public var workingDirectory: String?
    /// Extra xcodebuild arguments, e.g. `-configuration Debug`.
    public var extraArguments: [String] = []
    /// SSH destination (`user@host` or an ~/.ssh/config alias) of a CI machine for remote runs.
    public var remoteHost: String?
    /// Directory on the remote machine to sync the working tree into.
    public var remoteDirectory: String?

    /// Where each field came from, keyed by `Field.rawValue` (e.g. ".github/workflows/ci.yml").
    public var sources: [String: String] = [:]

    public init() {}

    public enum Field: String, CaseIterable, Sendable {
        case xcodeVersion = "xcode"
        case developerDir
        case platform
        case deviceName = "device"
        case osVersion = "os"
        case scheme
        case project
        case workspace
        case testPlan
        case onlyTesting
        case skipTesting
        case baseBranch
        case workingDirectory
        case extraArguments
        case remoteHost
        case remoteDirectory
    }

    public func source(of field: Field) -> String? { sources[field.rawValue] }

    /// Fields set in `other` replace fields here; provenance follows the value.
    public mutating func override(with other: SnapshotConfig) {
        func take<T>(_ keyPath: WritableKeyPath<SnapshotConfig, T?>, _ field: Field) {
            if let value = other[keyPath: keyPath] {
                self[keyPath: keyPath] = value
                sources[field.rawValue] = other.sources[field.rawValue]
            }
        }
        func takeList(_ keyPath: WritableKeyPath<SnapshotConfig, [String]>, _ field: Field) {
            if !other[keyPath: keyPath].isEmpty || other.sources[field.rawValue] != nil {
                self[keyPath: keyPath] = other[keyPath: keyPath]
                sources[field.rawValue] = other.sources[field.rawValue]
            }
        }
        take(\.xcodeVersion, .xcodeVersion)
        take(\.developerDir, .developerDir)
        take(\.platform, .platform)
        take(\.deviceName, .deviceName)
        take(\.osVersion, .osVersion)
        take(\.scheme, .scheme)
        take(\.project, .project)
        take(\.workspace, .workspace)
        take(\.testPlan, .testPlan)
        take(\.baseBranch, .baseBranch)
        take(\.workingDirectory, .workingDirectory)
        take(\.remoteHost, .remoteHost)
        take(\.remoteDirectory, .remoteDirectory)
        takeList(\.onlyTesting, .onlyTesting)
        takeList(\.skipTesting, .skipTesting)
        takeList(\.extraArguments, .extraArguments)
    }
}

extension SnapshotConfig {
    public static let overrideFileName = ".snapshotkit.yml"

    /// Parses `.snapshotkit.yml`. Unknown keys, and lists where a single value belongs, are
    /// reported so typos do not go unnoticed.
    public static func fromOverrideFile(_ text: String, source: String = overrideFileName) throws
        -> (SnapshotConfig, unknownKeys: [String], mistypedKeys: [String]) {
        let values = try MiniYAML.parse(text)
        var config = SnapshotConfig()
        var unknown: [String] = [], mistyped: [String] = []
        let aliases: [String: Field] = [
            "xcode": .xcodeVersion, "xcodeVersion": .xcodeVersion,
            "developerDir": .developerDir, "xcodePath": .developerDir,
            "platform": .platform,
            "device": .deviceName, "simulator": .deviceName,
            "os": .osVersion, "osVersion": .osVersion, "iosVersion": .osVersion,
            "scheme": .scheme, "project": .project, "workspace": .workspace,
            "testPlan": .testPlan,
            "onlyTesting": .onlyTesting, "skipTesting": .skipTesting,
            "baseBranch": .baseBranch, "workingDirectory": .workingDirectory,
            "extraArguments": .extraArguments,
            "remoteHost": .remoteHost, "remote": .remoteHost,
            "remoteDirectory": .remoteDirectory,
        ]
        for (key, value) in values {
            guard let field = aliases[key] else { unknown.append(key); continue }
            let takesList = [.onlyTesting, .skipTesting, .extraArguments].contains(field)
            guard takesList || value.string != nil else { mistyped.append(key); continue }
            config.sources[field.rawValue] = source
            switch field {
            case .xcodeVersion: config.xcodeVersion = value.string
            case .developerDir: config.developerDir = value.string
            case .platform: config.platform = value.string
            case .deviceName: config.deviceName = value.string
            case .osVersion: config.osVersion = value.string
            case .scheme: config.scheme = value.string
            case .project: config.project = value.string
            case .workspace: config.workspace = value.string
            case .testPlan: config.testPlan = value.string
            case .baseBranch: config.baseBranch = value.string
            case .workingDirectory: config.workingDirectory = value.string
            case .onlyTesting: config.onlyTesting = value.strings
            case .skipTesting: config.skipTesting = value.strings
            case .remoteHost: config.remoteHost = value.string
            case .remoteDirectory: config.remoteDirectory = value.string
            case .extraArguments:
                config.extraArguments = value.string.map(ShellWords.split) ?? value.strings
            }
        }
        return (config, unknown.sorted(), mistyped.sorted())
    }
}
