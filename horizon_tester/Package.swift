// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "horizon_tester",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
        .package(name: "StarCore", path: "../StarCore"),
    ],
    targets: [
        .executableTarget(
            name: "horizon_tester",
            dependencies: [
              .product(name: "ArgumentParser", package: "swift-argument-parser"),
              .product(name: "StarCore", package: "StarCore"),
            ],
            path: "Sources"
        )
    ]
)
