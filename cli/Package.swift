// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "star",
    platforms: [
        .macOS(.v10_15)
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.3"),
        .package(name: "StarCore", path: "../StarCore"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .executableTarget(
            name: "star",
            dependencies: [
              .product(name: "ArgumentParser", package: "swift-argument-parser"),
              .product(name: "StarCore", package: "StarCore"),
            ],
            linkerSettings: [
              .unsafeFlags(["-L../StarDecisionTrees",
                             "-Xlinker", "-force_load",
                             "-Xlinker", "../StarDecisionTrees/libStarDecisionTrees.a"
                           ]),
              .linkedLibrary("StarDecisionTrees")
            ]),
        .testTarget(
            name: "starTests",
            dependencies: ["star"]),
    ]
)


