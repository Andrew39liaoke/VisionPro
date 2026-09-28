// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamingCore",
    platforms: [.macOS(.v13), .visionOS(.v2)],
    products: [.library(name: "StreamingCore", targets: ["StreamingCore"])],
    targets: [
        .target(name: "StreamingCore"),
        .testTarget(name: "StreamingCoreTests", dependencies: ["StreamingCore"])
    ]
)
