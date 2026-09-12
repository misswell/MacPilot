// swift-tools-version: 6.0
import PackageDescription

/// Shared wire protocol for the MacPilot iPhone remote control.
///
/// `MacPilotRemoteProtocol` stays platform neutral: it only depends on
/// Foundation and CryptoKit so the same code compiles for the macOS app and the
/// iOS app. `MacPilotRemoteTransport` is the link layer below that wire
/// protocol — TCP and BLE L2CAP both look like the same byte stream from there —
/// and is shared so the two apps cannot drift on how a link opens or closes.
let package = Package(
    name: "MacPilotRemoteProtocol",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "MacPilotRemoteProtocol", targets: ["MacPilotRemoteProtocol"]),
        .library(name: "MacPilotRemoteTransport", targets: ["MacPilotRemoteTransport"])
    ],
    targets: [
        .target(name: "MacPilotRemoteProtocol"),
        .target(
            name: "MacPilotRemoteTransport",
            dependencies: ["MacPilotRemoteProtocol"]
        ),
        .testTarget(
            name: "MacPilotRemoteProtocolTests",
            dependencies: ["MacPilotRemoteProtocol", "MacPilotRemoteTransport"]
        )
    ]
)
