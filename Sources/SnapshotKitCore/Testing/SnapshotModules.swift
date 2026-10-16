import Foundation

/// Test targets that own `__Snapshots__` directories.
public enum SnapshotModules {
    /// Module (test target) names inferred from tracked snapshot paths: the nearest
    /// ancestor of `__Snapshots__` whose name ends in "Tests".
    public static func detect(in git: Git) -> [String] {
        modules(fromSnapshotPaths: git.lsFiles([":(glob)**/__Snapshots__/**"]))
    }

    public static func modules(fromSnapshotPaths paths: [String]) -> [String] {
        Set(paths.compactMap(module(forSnapshotPath:))).sorted()
    }

    /// The test target owning one snapshot path: the nearest ancestor of `__Snapshots__` whose
    /// name ends in "Tests", else the folder containing `__Snapshots__`.
    public static func module(forSnapshotPath path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard let snapIndex = components.firstIndex(of: "__Snapshots__") else { return nil }
        let ancestors = components[..<snapIndex]
        return ancestors.last(where: { $0.hasSuffix("Tests") }) ?? ancestors.last
    }
}
