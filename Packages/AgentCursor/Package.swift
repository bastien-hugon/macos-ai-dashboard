// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentCursor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentCursor", targets: ["AgentCursor"]),
    ],
    dependencies: [
        .package(path: "../DashCore"),
    ],
    targets: [
        .target(
            name: "AgentCursor",
            dependencies: [.product(name: "DashCore", package: "DashCore")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "AgentCursorTests",
            dependencies: [
                "AgentCursor",
                .product(name: "TestSupport", package: "DashCore"),
            ]
        ),
    ]
)
