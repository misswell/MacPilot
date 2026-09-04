// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPilot", targets: ["MacPilot"]),
        .executable(name: "MacPilotUpdater", targets: ["MacPilotUpdater"]),
        .executable(name: "MacPilotSystemHelper", targets: ["MacPilotSystemHelper"]),
        .library(name: "MacPilotOcclusionPatch", type: .dynamic, targets: ["MacPilotOcclusionPatch"])
    ],
    targets: [
        .target(name: "MacPilotSystemIPC"),
        .executableTarget(
            name: "MacPilot",
            dependencies: [
                "MacPilotRightClickKit",
                "MacPilotSystemIPC"
            ]
        ),
        .executableTarget(name: "MacPilotUpdater"),
        .executableTarget(
            name: "MacPilotSystemHelper",
            dependencies: ["MacPilotSystemIPC"]
        ),
        .target(
            name: "MacPilotRightClickKit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("FinderSync"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        .target(
            name: "MacPilotOcclusionPatch",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "MacPilotTests",
            dependencies: ["MacPilot", "MacPilotSystemIPC"]
        ),
        .testTarget(
            name: "MacPilotRightClickKitTests",
            dependencies: ["MacPilotRightClickKit"]
        )
    ]
)
