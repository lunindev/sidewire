// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SidewireCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SidewireCore", targets: ["SidewireCore"])
    ],
    dependencies: [
        .package(path: "../SidewireProtocol"),
        // Phase 7a security migration (docs/05, docs/09 §D11): P-256 device identity + a
        // minimal self-signed X.509 cert for certificate-based TLS 1.3. swift-certificates is
        // Apple's official X.509 package; it can sign a cert with a keychain-resident SecKey
        // (SecKeyWrapper), which is how we mint a SecIdentity without exporting the private key.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.0"),
    ],
    targets: [
        .target(
            name: "SidewireCore",
            dependencies: [
                "SidewireProtocol",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        .testTarget(
            name: "SidewireCoreTests",
            dependencies: ["SidewireCore", "SidewireProtocol"]
        )
    ]
)
