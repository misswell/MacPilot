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
        // FinderSync appex executable. The `_NSExtensionMain` entry point
        // replaces the usual `main`; Scripts/build-findersync.sh assembles the
        // resulting binary into the .appex bundle. SwiftUI is linked explicitly
        // so SwiftUICore reaches the linker through SwiftUI's re-export instead
        // of an autolink entry, which SwiftUICore's allowed-clients would reject.
        .executableTarget(
            name: "MacPilotFinderSync",
            dependencies: ["MacPilotRightClickKit"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
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
        ),
        .testTarget(
            name: "MacPilotFinderSyncTests",
            dependencies: [
                "MacPilotFinderSync",
                "MacPilotRightClickKit"
            ]
        )
    ]
)
