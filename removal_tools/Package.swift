// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "removal_tools",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "star-removal-verify", targets: ["star-removal-verify"]),
        .executable(name: "star-trail-inject", targets: ["star-trail-inject"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(name: "StarCore", path: "../StarCore"),
        .package(name: "StarCpp", path: "../StarCpp"),
    ],
    targets: [
        // Pure Swift: the measurements, label/threshold/baseline models and report. No OpenCV, so
        // its tests build and run anywhere `swift test` does.
        .target(name: "RemovalCore"),
        // Image decode/encode through StarCore's PixelatedImage.
        .target(
            name: "RemovalIO",
            dependencies: [
                "RemovalCore",
                .product(name: "StarCore", package: "StarCore"),
                .product(name: "StarCppBridge", package: "StarCpp"),
            ]
        ),
        .executableTarget(
            name: "star-removal-verify",
            dependencies: [
                "RemovalCore", "RemovalIO",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "StarCore", package: "StarCore"),
            ]
        ),
        .executableTarget(
            name: "star-trail-inject",
            dependencies: [
                "RemovalCore", "RemovalIO",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "StarCore", package: "StarCore"),
            ]
        ),
        .testTarget(name: "RemovalCoreTests", dependencies: ["RemovalCore"]),
    ]
)
