// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "TetherCore"),
        .target(name: "VirtualDisplayShim", linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("AppKit")]),
        .executableTarget(
            name: "Tether",
            dependencies: [
                "TetherCore",
                "VirtualDisplayShim",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        // Command Line Tools ship without XCTest/Swift Testing macros, so tests are a plain executable:
        // `swift run SelfTest`
        .executableTarget(name: "SelfTest", dependencies: ["TetherCore"]),
    ],
    swiftLanguageModes: [.v5]
)
