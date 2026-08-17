// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPilot", targets: ["MacPilot"]),
        .executable(name: "MacPilotUpdater", targets: ["MacPilotUpdater"]),
        .library(name: "MacPilotOcclusionPatch", type: .dynamic, targets: ["MacPilotOcclusionPatch"])
    ],
    targets: [
        .executableTarget(
            name: "MacPilot",
            dependencies: ["MacPilotRightClickKit"]
        ),
        .executableTarget(name: "MacPilotUpdater"),
        .target(
            name: "MacPilotRightClickKit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("FinderSync"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        .target(
            name: "MacPilotOcclusionPatch",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(name: "MacPilotTests", dependencies: ["MacPilot"])
    ]
)
