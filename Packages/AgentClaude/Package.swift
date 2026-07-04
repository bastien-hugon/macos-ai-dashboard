// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentClaude",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentClaude", targets: ["AgentClaude"]),
    ],
    dependencies: [
        .package(path: "../DashCore"),
    ],
    targets: [
        .target(
            name: "AgentClaude",
            dependencies: [.product(name: "DashCore", package: "DashCore")]
        ),
        .testTarget(
            name: "AgentClaudeTests",
            dependencies: [
                "AgentClaude",
                .product(name: "TestSupport", package: "DashCore"),
            ]
        ),
    ]
)
