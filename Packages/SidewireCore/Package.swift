// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SidewireCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SidewireCore", targets: ["SidewireCore"])
    ],
    dependencies: [
        .package(path: "../SidewireProtocol")
    ],
    targets: [
        .target(
            name: "SidewireCore",
            dependencies: ["SidewireProtocol"]
        ),
        .testTarget(
            name: "SidewireCoreTests",
            dependencies: ["SidewireCore", "SidewireProtocol"]
        )
    ]
)
