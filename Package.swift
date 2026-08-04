// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPilot", targets: ["MacPilot"]),
        .executable(name: "MacPilotUpdater", targets: ["MacPilotUpdater"])
    ],
    targets: [
        .executableTarget(name: "MacPilot"),
        .executableTarget(name: "MacPilotUpdater"),
        .testTarget(name: "MacPilotTests", dependencies: ["MacPilot"])
    ]
)
