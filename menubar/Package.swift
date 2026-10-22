// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LanModelBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LanModelCore", targets: ["LanModelCore"]),
        .executable(name: "LanModelBar", targets: ["LanModelBar"]),
    ],
    targets: [
        .target(name: "LanModelCore"),
        .executableTarget(name: "LanModelBar", dependencies: ["LanModelCore"]),
        .testTarget(name: "LanModelCoreTests", dependencies: ["LanModelCore"]),
    ]
)
