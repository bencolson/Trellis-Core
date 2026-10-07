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
            dependencies: ["TrellisCLIKit"],
            path: "trellis-cli/Sources/trellis"
        ),
        // The CLI's command logic, split out so the end-to-end tests can drive
        // it without spawning the executable.
        .target(
            name: "TrellisCLIKit",
            dependencies: ["TrellisCore"],
            path: "trellis-cli/Sources/TrellisCLIKit"
        ),
        .testTarget(
            name: "TrellisCLITests",
            dependencies: ["TrellisCLIKit", "TrellisCore"],
            path: "trellis-cli/Tests/TrellisCLITests"
        ),
    ]
)
