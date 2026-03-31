// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "horizon_test_bench",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(name: "StarCore", path: "../StarCore"),
    ],
    targets: [
        .executableTarget(
            name: "horizon_test_bench",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "StarCore", package: "StarCore"),
            ]
        )
    ]
)
