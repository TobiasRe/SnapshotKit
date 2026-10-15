import Foundation

/// Test targets that own `__Snapshots__` directories.
public enum SnapshotModules {
    /// Module (test target) names inferred from tracked snapshot paths: the nearest
    /// ancestor of `__Snapshots__` whose name ends in "Tests".
    public static func detect(in git: Git) -> [String] {
        modules(fromSnapshotPaths: git.lsFiles([":(glob)**/__Snapshots__/**"]))
    }

    public static func modules(fromSnapshotPaths paths: [String]) -> [String] {
        var found = Set<String>()
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard let snapIndex = components.firstIndex(of: "__Snapshots__") else { continue }
            let ancestors = components[..<snapIndex]
            if let module = ancestors.last(where: { $0.hasSuffix("Tests") }) {
                found.insert(module)
            } else if let parent = ancestors.last {
                found.insert(parent)
            }
        }
        return found.sorted()
    }
}
