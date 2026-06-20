// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CodexPortCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "CodexPortCore",
            targets: ["CodexPortCore"]
        ),
        .library(
            name: "CodexPortShared",
            targets: ["CodexPortShared"]
        ),
        .library(
            name: "CodexPortHostAgentCore",
            targets: ["CodexPortHostAgentCore"]
        ),
        .library(
            name: "CodexPortRelayCore",
            targets: ["CodexPortRelayCore"]
        ),
        .library(
            name: "CodexPortWebRTC",
            targets: ["CodexPortWebRTC"]
        ),
        .executable(
            name: "codexport-host-agent",
            targets: ["CodexPortHostAgent"]
        ),
        .executable(
            name: "codexport-host-agent-menu",
            targets: ["CodexPortHostAgentMenuApp"]
        ),
        .executable(
            name: "codexport-relay",
            targets: ["CodexPortRelayService"]
        ),
        .executable(
            name: "codexport-webrtc-sidecar",
            targets: ["CodexPortWebRTCSidecar"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "148.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "CodexPortCore",
            dependencies: [
                "CodexPortWebRTC",
                "CodexPortShared",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "CodexPortShared",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "CodexPortHostAgentCore",
            dependencies: ["CodexPortShared", "CodexPortWebRTC"]
        ),
        .target(
            name: "CodexPortRelayCore",
            dependencies: [
                "CodexPortShared",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        .target(
            name: "CodexPortRelayTestSupport",
            dependencies: ["CodexPortShared"]
        ),
        .target(
            name: "CodexPortWebRTC",
            dependencies: [
                "CodexPortShared",
                .product(
                    name: "WebRTC",
                    package: "WebRTC",
                    condition: .when(platforms: [.iOS, .macCatalyst])
                ),
            ]
        ),
        .executableTarget(
            name: "CodexPortHostAgent",
            dependencies: ["CodexPortHostAgentCore", "CodexPortRelayCore", "CodexPortWebRTC"]
        ),
        .executableTarget(
            name: "CodexPortHostAgentMenuApp",
            dependencies: ["CodexPortHostAgentCore", "CodexPortShared", "CodexPortWebRTC"]
        ),
        .executableTarget(
            name: "CodexPortRelayService",
            dependencies: ["CodexPortRelayCore", "CodexPortShared"]
        ),
        .executableTarget(
            name: "CodexPortWebRTCSidecar",
            dependencies: ["CodexPortWebRTC"]
        ),
        .testTarget(
            name: "CodexPortCoreTests",
            dependencies: ["CodexPortCore", "CodexPortShared"]
        ),
        .testTarget(
            name: "CodexPortHostAgentCoreTests",
            dependencies: ["CodexPortShared", "CodexPortHostAgentCore"]
        ),
        .testTarget(
            name: "CodexPortRelayTestSupportTests",
            dependencies: ["CodexPortShared", "CodexPortRelayTestSupport"]
        ),
        .testTarget(
            name: "CodexPortRelayIntegrationTests",
            dependencies: ["CodexPortCore", "CodexPortHostAgentCore", "CodexPortRelayCore", "CodexPortShared"]
        ),
        .testTarget(
            name: "CodexPortWebRTCTests",
            dependencies: ["CodexPortCore", "CodexPortHostAgentCore", "CodexPortShared", "CodexPortWebRTC"]
        ),
    ]
)
