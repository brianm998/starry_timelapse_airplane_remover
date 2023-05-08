// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "decision_tree_generator",
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
        .package(name: "StarCore", path: "../StarCore"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .executableTarget(
            name: "decision_tree_generator",
            dependencies: [
              .product(name: "ArgumentParser", package: "swift-argument-parser"),
              .product(name: "StarCore", package: "StarCore"),
            ],
            linkerSettings: [
              .unsafeFlags([
                             "-L../StarDecisionTrees",
                             "-Xlinker", "-all_load",
                           ]),
              .linkedLibrary("StarDecisionTrees")
            ]),
        .testTarget(
            name: "decision_tree_generatorTests",
            dependencies: ["decision_tree_generator"]),
    ]
)
