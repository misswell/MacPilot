// swift-tools-version: 6.0
import PackageDescription

/// Shared wire protocol for the MacPilot iPhone remote control.
///
/// The package is deliberately platform neutral: it only depends on Foundation
/// and CryptoKit so the same code compiles for the macOS app and the iOS app.
let package = Package(
    name: "MacPilotRemoteProtocol",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "MacPilotRemoteProtocol", targets: ["MacPilotRemoteProtocol"])
    ],
    targets: [
        .target(name: "MacPilotRemoteProtocol"),
        .testTarget(
            name: "MacPilotRemoteProtocolTests",
            dependencies: ["MacPilotRemoteProtocol"]
        )
    ]
)
