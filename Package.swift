// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SnowStorm",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SnowStorm", path: "Sources/SnowStorm")
    ]
)
