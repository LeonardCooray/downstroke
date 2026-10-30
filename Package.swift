// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Downstroke",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "DownstrokeCore"),
        .executableTarget(name: "Downstroke", dependencies: ["DownstrokeCore"]),
        .testTarget(name: "DownstrokeCoreTests", dependencies: ["DownstrokeCore"]),
    ]
)
