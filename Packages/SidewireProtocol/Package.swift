// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SidewireProtocol",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SidewireProtocol", targets: ["SidewireProtocol"])
    ],
    targets: [
        .target(name: "SidewireProtocol"),
        .testTarget(
            name: "SidewireProtocolTests",
            dependencies: ["SidewireProtocol"]
        )
    ]
)
