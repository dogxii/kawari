// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kawari",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Kawari", path: "Sources/Kawari"),
        .testTarget(name: "KawariTests", dependencies: ["Kawari"], path: "Tests/KawariTests"),
    ]
)
