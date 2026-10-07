// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrellisCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TrellisCore", targets: ["TrellisCore"]),
        .executable(name: "trellis", targets: ["trellis"]),
    ],
    targets: [
        // All colour maths, Hald and .cube I/O. No UI. Keep it portable (Linux CI builds it).
        .target(
            name: "TrellisCore",
            path: "TrellisCore/Sources/TrellisCore"
        ),
        .testTarget(
            name: "TrellisCoreTests",
            dependencies: ["TrellisCore"],
            path: "TrellisCore/Tests/TrellisCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .executableTarget(
            name: "trellis",
            dependencies: ["TrellisCore"],
            path: "trellis-cli/Sources/trellis"
        ),
    ]
)
