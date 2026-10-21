// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Sekisho",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SekishoApp", targets: ["SekishoApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.10.0"..<"5.0.0"),
    ],
    targets: [
        .target(name: "SekishoCore", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
        ], path: "Sources/SekishoCore"),
        .executableTarget(name: "SekishoApp", dependencies: ["SekishoCore"], path: "Sources/SekishoApp"),
        .testTarget(name: "SekishoTests", dependencies: [
            "SekishoCore",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ], path: "Tests/SekishoTests"),
    ],
    swiftLanguageModes: [.v5]
)
