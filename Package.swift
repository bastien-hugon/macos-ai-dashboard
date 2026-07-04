// swift-tools-version: 6.0
// AgentDash (nom provisoire) — racine du workspace SPM.
// Structure conforme à plan/01-architecture.md §3 : deux exécutables (app + agentdash-hook)
// et des packages locaux dans Packages/ avec dépendances orientées vers DashCore.
import PackageDescription

let package = Package(
    name: "AgentDash",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Packages/DashCore"),
        .package(path: "Packages/NotchUI"),
        .package(path: "Packages/AgentClaude"),
        .package(path: "Packages/AgentCursor"),
        .package(path: "Packages/ServersKit"),
    ],
    targets: [
        .executableTarget(
            name: "AgentDash",
            dependencies: [
                .product(name: "DashCore", package: "DashCore"),
                .product(name: "NotchUI", package: "NotchUI"),
                .product(name: "AgentClaude", package: "AgentClaude"),
                .product(name: "AgentCursor", package: "AgentCursor"),
                .product(name: "ServersKit", package: "ServersKit"),
            ],
            path: "Apps/AgentDash/Sources",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        // agentdash-hook : binaire compagnon autonome, aucune dépendance (01 · §3.1 HookRelay).
        .executableTarget(
            name: "agentdash-hook",
            path: "Apps/HookRelay/Sources"
        ),
    ]
)
