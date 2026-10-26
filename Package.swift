// swift-tools-version:6.2
// 6.2 comes with Xcode 26, the first with the macOS 26 SDK the app builds against: older Xcodes stop here.
import PackageDescription

let package = Package(
    name: "SnapshotKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SnapshotKitCore", targets: ["SnapshotKitCore"]),
        // The app's code. SnapshotKit.xcodeproj builds it into SnapshotKit.app, with the icon and Info.plist.
        .library(name: "SnapshotKitUI", targets: ["SnapshotKitUI"]),
        .executable(name: "snapkit", targets: ["SnapshotKitCLI"]),
    ],
    dependencies: [
        // Only used by the app's own snapshot tests.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(name: "SnapshotKitCore"),
        .target(name: "SnapshotKitUI", dependencies: ["SnapshotKitCore"]),
        .executableTarget(name: "SnapshotKitCLI", dependencies: ["SnapshotKitCore"]),
        .testTarget(
            name: "SnapshotKitCoreTests",
            dependencies: ["SnapshotKitCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SnapshotKitAppTests",
            dependencies: [
                "SnapshotKitUI",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
