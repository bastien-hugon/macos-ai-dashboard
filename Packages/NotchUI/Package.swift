// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NotchUI", targets: ["NotchUI"]),
    ],
    dependencies: [
        .package(path: "../DashCore"),
    ],
    targets: [
        .target(
            name: "NotchUI",
            dependencies: [.product(name: "DashCore", package: "DashCore")]
        ),
        .testTarget(
            name: "NotchUITests",
            dependencies: ["NotchUI"]
        ),
    ]
)
