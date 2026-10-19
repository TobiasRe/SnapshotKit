// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SnapshotKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SnapshotKitCore", targets: ["SnapshotKitCore"]),
        .executable(name: "SnapshotKit", targets: ["SnapshotKit"]),
        .executable(name: "snapkit", targets: ["SnapshotKitCLI"]),
    ],
    dependencies: [
        // Only used by the app's own snapshot tests.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(name: "SnapshotKitCore"),
        .executableTarget(name: "SnapshotKit", dependencies: ["SnapshotKitCore"]),
        .executableTarget(name: "SnapshotKitCLI", dependencies: ["SnapshotKitCore"]),
        .testTarget(
            name: "SnapshotKitCoreTests",
            dependencies: ["SnapshotKitCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SnapshotKitAppTests",
            dependencies: [
                "SnapshotKit",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
