// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "airstar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AirstarCore", targets: ["AirstarCore"]),
        .executable(name: "airstar-cli", targets: ["airstar-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
    ],
    targets: [
        .target(
            name: "AirstarCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "airstar-cli",
            dependencies: [
                "AirstarCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "AirstarCoreTests",
            dependencies: [
                "AirstarCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "BigInt", package: "BigInt"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
