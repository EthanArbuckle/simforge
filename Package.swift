// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "simforge",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "simforge", targets: ["simforge"]),
        .executable(name: "simforge-cli", targets: ["simforge-cli"])
    ],
    dependencies: [
    ],
    targets: [
        .executableTarget(
            name: "simforge",
            dependencies: [],
            cSettings: [
                .headerSearchPath(".")
            ]
        ),
        .executableTarget(
            name: "simforge-cli",
            dependencies: []
        )
    ]
) 