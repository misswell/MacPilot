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
        // Dock Groups：每个分组对应一个由 MacPilot 生成的 Helper App，
        // 复用同一个 binary，只靠 Bundle ID / 图标 / 名称区分。
        .executable(name: "MacPilotDockHelper", targets: ["MacPilotDockHelper"]),
        .library(name: "MacPilotOcclusionPatch", type: .dynamic, targets: ["MacPilotOcclusionPatch"])
    ],
    dependencies: [
        // Shared wire protocol between the macOS app and the iOS remote app.
        .package(path: "Packages/MacPilotRemoteProtocol")
    ],
    targets: [
        // Dock Groups 的共享核心：主程序写配置、Helper 读配置、测试校验完整性，
        // 三方共用同一份模型，避免任何一方私自触碰第三方 App。
        .target(
            name: "MacPilotDockGroupsCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        .executableTarget(
            name: "MacPilot",
            dependencies: [
                "MacPilotRightClickKit",
                "MacPilotPowerIPC",
                "MacPilotDockGroupsCore",
                .product(name: "MacPilotRemoteProtocol", package: "MacPilotRemoteProtocol"),
                .product(name: "MacPilotRemoteTransport", package: "MacPilotRemoteProtocol")
            ]
        ),
        // Dock Groups 的 Helper：每个分组一个 App，复用同一个 binary。
        .executableTarget(
            name: "MacPilotDockHelper",
            dependencies: ["MacPilotDockGroupsCore"]
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
                "MacPilotDockGroupsCore",
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
