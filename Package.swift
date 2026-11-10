// swift-tools-version: 6.2
import PackageDescription

// LushKit — the remote-toy client as a self-contained SPM: Connect transport for
// the control plane, the /live/v1 socket, the Lovense BLE layer, and the UI.
// Talks to mvLush. A host app (or LushLab) adds a thin wrapper that supplies
// identity + a token.
//
// Mirrors GarageKit's shape: the kit never owns login — the host injects a
// `tokenProvider`. Swift 6 strict concurrency from line one.
let package = Package(
    name: "LushKit",
    platforms: [.iOS(.v26)], // iOS-only
    products: [
        .library(name: "LushKit", targets: ["LushKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/connectrpc/connect-swift", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.27.0"),
    ],
    targets: [
        .target(
            name: "LushKit",
            dependencies: [
                .product(name: "Connect", package: "connect-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LushKitTests",
            dependencies: ["LushKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
