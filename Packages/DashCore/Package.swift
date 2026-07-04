// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DashCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DashCore", targets: ["DashCore"]),
        // TestSupport vit dans ce package pour éviter un cycle DashCore ↔ TestSupport
        // (15 · REQ-TST-01..06 : sandbox de home, horloge pilotable, garde anti-destruction).
        .library(name: "TestSupport", targets: ["TestSupport"]),
    ],
    targets: [
        .target(name: "DashCore"),
        .target(name: "TestSupport", dependencies: ["DashCore"]),
        .testTarget(name: "DashCoreTests", dependencies: ["DashCore", "TestSupport"]),
    ]
)
