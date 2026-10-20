import Foundation

public struct XcodeInstall: Equatable, Sendable, Codable {
    public var path: String
    public var version: String
    public var build: String?

    public init(path: String, version: String, build: String? = nil) {
        self.path = path
        self.version = version
        self.build = build
    }

    public var developerDir: String { path + "/Contents/Developer" }
}

public struct Simulator: Equatable, Sendable, Codable {
    public var name: String
    public var udid: String
    public var osVersion: String
    public var platform: String
    public var state: String

    public init(name: String, udid: String, osVersion: String, platform: String, state: String) {
        self.name = name
        self.udid = udid
        self.osVersion = osVersion
        self.platform = platform
        self.state = state
    }
}

/// A config checked against the machine: the Xcode to use and the simulator to run on.
public struct TestEnvironment: Sendable {
    public var xcode: XcodeInstall
    public var simulator: Simulator
    /// True when CI does not pin Xcode and the currently selected one is used.
    public var xcodeIsDefault: Bool

    public init(xcode: XcodeInstall, simulator: Simulator, xcodeIsDefault: Bool) {
        self.xcode = xcode
        self.simulator = simulator
        self.xcodeIsDefault = xcodeIsDefault
    }

    public var destination: String { "platform=\(simulator.platform) Simulator,id=\(simulator.udid)" }
    public var processEnvironment: [String: String] { ["DEVELOPER_DIR": xcode.developerDir] }
}

public enum EnvironmentError: Error, LocalizedError, Equatable {
    case xcodeNotInstalled(required: String, source: String?, installed: [XcodeInstall])
    case xcodePathMissing(String)
    case noXcode
    case runtimeMissing(platform: String, os: String, installed: [String], xcode: String)
    case simulatorMissing(name: String, platform: String, os: String, available: [String])
    case noDestination(available: [String])
    case simctlFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .xcodeNotInstalled(required, source, installed):
            let from = source.map { " (required by \($0))" } ?? ""
            let list = installed.isEmpty ? "none found" : installed.map { "\($0.version) at \($0.path)" }.joined(separator: ", ")
            return "Xcode \(required) is not installed\(from). Installed: \(list). Install it (e.g. from developer.apple.com/download or with `xcodes install \(required)`), or set `xcode:` in .snapshotkit.yml."
        case let .xcodePathMissing(path):
            return "Xcode at \(path) does not exist. Install it there or set `xcode:` / `developerDir:` in .snapshotkit.yml."
        case .noXcode:
            return "No Xcode installation found. Install Xcode and run `xcode-select -s /Applications/Xcode.app`."
        case let .runtimeMissing(platform, os, installed, xcode):
            let list = installed.isEmpty ? "none" : installed.joined(separator: ", ")
            return "The \(platform) \(os) simulator runtime is not installed for Xcode \(xcode). Installed runtimes: \(list). Install it with `xcodebuild -downloadPlatform \(platform) -buildVersion \(os)` or in Xcode › Settings › Components."
        case let .simulatorMissing(name, platform, os, available):
            let list = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "No '\(name)' simulator on \(platform) \(os). Available on that runtime: \(list). Create one with `xcrun simctl create \"\(name)\" \"\(name)\" <runtime-id>`, or set `device:` in .snapshotkit.yml."
        case let .noDestination(available):
            let list = available.prefix(8).joined(separator: ", ")
            return "No simulator is configured: CI has no `-destination` with a device name. Set `device:` (and optionally `os:`) in .snapshotkit.yml. Available: \(list)"
        case let .simctlFailed(message):
            return "Could not list simulators: \(message)"
        }
    }
}

public enum EnvironmentValidator {
    /// Directories searched for `Xcode*.app`. Overridable for tests via `SNAPSHOTKIT_XCODE_SEARCH_PATHS`.
    public static var searchDirectories: [String] {
        if let custom = ProcessInfo.processInfo.environment["SNAPSHOTKIT_XCODE_SEARCH_PATHS"] {
            return custom.split(separator: ":").map(String.init)
        }
        return ["/Applications", NSHomeDirectory() + "/Applications"]
    }

    /// Every Xcode in `searchDirectories` plus the one `xcode-select` points at, newest first.
    public static func installedXcodes() -> [XcodeInstall] {
        var installs: [XcodeInstall] = []
        let fm = FileManager.default
        var candidates: [String] = []
        for dir in searchDirectories {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            candidates += entries.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.map { dir + "/" + $0 }
        }
        if let selected = try? Shell.output(["xcode-select", "-p"]), selected.hasSuffix("/Contents/Developer") {
            candidates.append(String(selected.dropLast("/Contents/Developer".count)))
        }
        for path in candidates {
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard !installs.contains(where: { $0.path == resolved }), let install = xcode(at: resolved) else { continue }
            installs.append(install)
        }
        return installs.sorted { compareVersions($0.version, $1.version) == .orderedDescending }
    }

    public static func xcode(at appPath: String) -> XcodeInstall? {
        let plist = appPath + "/Contents/version.plist"
        guard FileManager.default.fileExists(atPath: appPath + "/Contents/Developer"),
              let data = FileManager.default.contents(atPath: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = dict["CFBundleShortVersionString"] as? String
        else { return nil }
        return XcodeInstall(path: appPath, version: version, build: dict["ProductBuildVersion"] as? String)
    }

    /// The Xcode the config asks for, on this machine.
    public static func selectXcode(for config: SnapshotConfig, installed: [XcodeInstall] = installedXcodes()) throws -> (XcodeInstall, isDefault: Bool) {
        let selected = (try? Shell.output(["xcode-select", "-p"])).flatMap { path -> XcodeInstall? in
            guard path.hasSuffix("/Contents/Developer") else { return nil }
            return xcode(at: String(path.dropLast("/Contents/Developer".count)))
        }
        return try selectXcode(for: config, installed: installed, selected: selected, lookup: { xcode(at: $0) })
    }

    /// Machine-independent selection, also used for remote hosts.
    public static func selectXcode(
        for config: SnapshotConfig, installed: [XcodeInstall], selected: XcodeInstall?,
        lookup: (String) -> XcodeInstall?
    ) throws -> (XcodeInstall, isDefault: Bool) {
        if let dir = config.developerDir {
            var app = dir
            if app.hasSuffix("/") { app.removeLast() }
            if app.hasSuffix("/Contents/Developer") { app = String(app.dropLast("/Contents/Developer".count)) }
            guard let install = lookup(app) else { throw EnvironmentError.xcodePathMissing(app) }
            if config.xcodeVersion == nil { return (install, false) }
        }
        if let required = config.xcodeVersion {
            let matches = installed.filter { versionMatches(installed: $0.version, required: required) }
            guard let best = matches.first else {
                throw EnvironmentError.xcodeNotInstalled(required: required, source: config.source(of: .xcodeVersion), installed: installed)
            }
            return (best, false)
        }
        if let selected { return (selected, true) }
        guard let first = installed.first else { throw EnvironmentError.noXcode }
        return (first, true)
    }

    /// "X" matches "X.Y"; "X.Y" matches "X.Y" and "X.Y.0"; "X.1" does not match "X.10".
    public static func versionMatches(installed: String, required: String) -> Bool {
        let have = installed.split(separator: ".").map { Int($0) ?? -1 }
        let want = required.split(separator: ".").map { Int($0) ?? -1 }
        for (i, w) in want.enumerated() {
            let h = i < have.count ? have[i] : 0
            if h != w { return false }
        }
        return true
    }

    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }

    // MARK: - Simulators

    struct SimctlListing: Decodable {
        struct Device: Decodable {
            var name: String
            var udid: String
            var state: String
            var isAvailable: Bool?
        }
        var devices: [String: [Device]]
    }

    /// All available simulators, as reported by the given Xcode's simctl.
    public static func simulators(xcode: XcodeInstall) throws -> [Simulator] {
        let result = try Shell.run(["xcrun", "simctl", "list", "devices", "available", "-j"], environment: ["DEVELOPER_DIR": xcode.developerDir])
        guard result.succeeded else { throw EnvironmentError.simctlFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return try parseSimulators(Data(result.stdout.utf8))
    }

    public static func parseSimulators(_ json: Data) throws -> [Simulator] {
        let listing = try JSONDecoder().decode(SimctlListing.self, from: json)
        var sims: [Simulator] = []
        for (runtime, devices) in listing.devices {
            guard let (platform, os) = parseRuntime(runtime) else { continue }
            for d in devices where d.isAvailable ?? true {
                sims.append(Simulator(name: d.name, udid: d.udid, osVersion: os, platform: platform, state: d.state))
            }
        }
        return sims.sorted {
            $0.osVersion == $1.osVersion ? $0.name < $1.name : compareVersions($0.osVersion, $1.osVersion) == .orderedDescending
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-<major>-<minor>` → ("iOS", "<major>.<minor>").
    public static func parseRuntime(_ identifier: String) -> (String, String)? {
        guard let last = identifier.split(separator: ".").last else { return nil }
        let parts = last.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        var platform = String(parts[0])
        if platform == "xrOS" { platform = "visionOS" }
        return (platform, parts.dropFirst().joined(separator: "."))
    }

    /// Picks the simulator the config names. `os` may be omitted or "latest".
    public static func selectSimulator(for config: SnapshotConfig, from simulators: [Simulator], xcode: XcodeInstall) throws -> Simulator {
        let platform = (config.platform ?? "iOS Simulator").replacingOccurrences(of: " Simulator", with: "")
        let onPlatform = simulators.filter { $0.platform == platform }
        guard let name = config.deviceName else {
            throw EnvironmentError.noDestination(available: onPlatform.map { "\($0.name) (\($0.osVersion))" })
        }
        let os = config.osVersion.flatMap { $0.lowercased() == "latest" ? nil : $0 }
        let candidates: [Simulator]
        if let os {
            let onRuntime = onPlatform.filter { versionMatches(installed: $0.osVersion, required: os) }
            guard !onRuntime.isEmpty else {
                let runtimes = Array(Set(onPlatform.map(\.osVersion))).sorted { compareVersions($0, $1) == .orderedDescending }
                throw EnvironmentError.runtimeMissing(platform: platform, os: os, installed: runtimes.map { "\(platform) \($0)" }, xcode: xcode.version)
            }
            candidates = onRuntime.filter { $0.name == name }
            if candidates.isEmpty {
                throw EnvironmentError.simulatorMissing(name: name, platform: platform, os: os, available: Array(Set(onRuntime.map(\.name))).sorted())
            }
        } else {
            candidates = onPlatform.filter { $0.name == name }
            if candidates.isEmpty {
                let latest = onPlatform.first?.osVersion ?? "latest"
                throw EnvironmentError.simulatorMissing(name: name, platform: platform, os: latest, available: Array(Set(onPlatform.map(\.name))).sorted())
            }
        }
        // Prefer an already booted device to save boot time.
        return candidates.first { $0.state == "Booted" } ?? candidates[0]
    }

    /// Full check: Xcode present, simulator present.
    public static func validate(_ config: SnapshotConfig) throws -> TestEnvironment {
        let (xcode, isDefault) = try selectXcode(for: config)
        let sims = try simulators(xcode: xcode)
        let sim = try selectSimulator(for: config, from: sims, xcode: xcode)
        return TestEnvironment(xcode: xcode, simulator: sim, xcodeIsDefault: isDefault)
    }
}
