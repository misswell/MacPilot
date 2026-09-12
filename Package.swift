// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPilot", targets: ["MacPilot"]),
        .executable(name: "MacPilotUpdater", targets: ["MacPilotUpdater"]),
        .executable(name: "MacPilotPowerHelper", targets: ["MacPilotPowerHelper"]),
        .library(name: "MacPilotPowerIPC", targets: ["MacPilotPowerIPC"]),
        .library(name: "MacPilotOcclusionPatch", type: .dynamic, targets: ["MacPilotOcclusionPatch"])
    ],
    dependencies: [
        // Shared wire protocol between the macOS app and the iOS remote app.
        .package(path: "Packages/MacPilotRemoteProtocol")
    ],
    targets: [
        .executableTarget(
            name: "MacPilot",
            dependencies: [
                "MacPilotRightClickKit",
                "MacPilotPowerIPC",
                .product(name: "MacPilotRemoteProtocol", package: "MacPilotRemoteProtocol"),
                .product(name: "MacPilotRemoteTransport", package: "MacPilotRemoteProtocol")
            ]
        ),
        // Wire protocol shared by the app and its privileged power helper.
        // Contains only types and pure logic, never privileged operations.
        .target(name: "MacPilotPowerIPC"),
        // Root LaunchDaemon providing the `pmset disablesleep` capability.
        .executableTarget(
            name: "MacPilotPowerHelper",
            dependencies: ["MacPilotPowerIPC"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "MacPilotUpdater",
            dependencies: ["MacPilotUpdaterSupport"]
        ),
        .target(name: "MacPilotUpdaterSupport"),
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
            dependencies: [
                "MacPilot",
                "MacPilotPowerIPC",
                .product(name: "MacPilotRemoteProtocol", package: "MacPilotRemoteProtocol")
            ]
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
        ),
        .testTarget(
            name: "MacPilotUpdaterSupportTests",
            dependencies: ["MacPilotUpdaterSupport"]
        )
    ]
)
