// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentTooling",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "AgentTooling", targets: ["AgentToolingApp"]),
        .executable(name: "agent-tooling", targets: ["AgentToolingCLI"]),
        .library(name: "AgentToolingCore", targets: ["AgentToolingCore"]),
    ],
    targets: [
        .target(
            name: "AgentToolingCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "AgentToolingApp",
            dependencies: ["AgentToolingCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "AgentToolingCLI",
            dependencies: ["AgentToolingCore"]
        ),
        .testTarget(
            name: "AgentToolingCoreTests",
            dependencies: ["AgentToolingCore"]
        ),
        .testTarget(
            name: "AgentToolingAppTests",
            dependencies: ["AgentToolingApp", "AgentToolingCore"]
        ),
    ]
)
