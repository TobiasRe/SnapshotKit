// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SnapshotKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SnapshotKitCore", targets: ["SnapshotKitCore"]),
        .executable(name: "SnapshotKit", targets: ["SnapshotKit"]),
        .executable(name: "snapkit", targets: ["snapkit"]),
    ],
    targets: [
        .target(name: "SnapshotKitCore"),
        .executableTarget(name: "SnapshotKit", dependencies: ["SnapshotKitCore"]),
        .executableTarget(name: "snapkit", dependencies: ["SnapshotKitCore"]),
        .testTarget(
            name: "SnapshotKitCoreTests",
            dependencies: ["SnapshotKitCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
