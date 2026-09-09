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
        .executable(name: "agent-tooling-mcp", targets: ["AgentToolingMCP"]),
        .library(name: "AgentToolingCore", targets: ["AgentToolingCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")
    ],
    targets: [
        .target(
            name: "AgentToolingCore",
            dependencies: [.product(name: "Yams", package: "Yams")],
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
        .executableTarget(
            name: "AgentToolingMCP",
            dependencies: ["AgentToolingCore"]
        ),
        .testTarget(
            name: "AgentToolingCoreTests",
            dependencies: ["AgentToolingCore"]
        ),
        .testTarget(
            name: "AgentToolingMCPTests",
            dependencies: ["AgentToolingMCP", "AgentToolingCore"]
        ),
        .testTarget(
            name: "AgentToolingAppTests",
            dependencies: ["AgentToolingApp", "AgentToolingCore"]
        ),
    ]
)
