// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ServersKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ServersKit", targets: ["ServersKit"]),
    ],
    dependencies: [
        .package(path: "../DashCore"),
    ],
    targets: [
        .target(
            name: "ServersKit",
            dependencies: [.product(name: "DashCore", package: "DashCore")]
        ),
        .testTarget(
            name: "ServersKitTests",
            dependencies: ["ServersKit"]
        ),
    ]
)
