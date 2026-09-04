// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NuboKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "NuboCore", targets: ["NuboCore"]),
        .library(name: "NuboProtocol", targets: ["NuboProtocol"]),
        .library(name: "NuboNetworking", targets: ["NuboNetworking"]),
        .library(name: "NuboVideo", targets: ["NuboVideo"]),
        .library(name: "NuboAudio", targets: ["NuboAudio"]),
        .library(name: "NuboInput", targets: ["NuboInput"]),
        .library(name: "NuboDesign", targets: ["NuboDesign"])
    ],
    targets: [
        .target(name: "NuboCore"),
        .target(name: "NuboProtocol", dependencies: ["NuboCore"]),
        .target(name: "NuboNetworking", dependencies: ["NuboCore", "NuboProtocol"]),
        .target(name: "NuboVideo", dependencies: ["NuboCore", "NuboProtocol"]),
        .target(name: "NuboAudio", dependencies: ["NuboCore", "NuboProtocol"]),
        .target(name: "NuboInput", dependencies: ["NuboCore", "NuboProtocol"]),
        .target(name: "NuboDesign", dependencies: ["NuboCore"]),
        .testTarget(name: "NuboCoreTests", dependencies: ["NuboCore"]),
        .testTarget(name: "NuboProtocolTests", dependencies: ["NuboProtocol"]),
        .testTarget(name: "NuboInputTests", dependencies: ["NuboInput"]),
        .testTarget(name: "NuboNetworkingTests", dependencies: ["NuboNetworking"])
    ]
)
