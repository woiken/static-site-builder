// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "woiken-static-builder",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/funcmike/rabbitmq-nio.git", exact: "0.1.0-beta4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "StaticBuilder",
            dependencies: [
                .product(name: "AMQPClient", package: "rabbitmq-nio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SotoS3", package: "soto"),
            ],
            path: "Sources/StaticBuilder"
        ),
        .testTarget(
            name: "StaticBuilderTests",
            dependencies: ["StaticBuilder"],
            path: "Tests/StaticBuilderTests"
        ),
    ]
)
