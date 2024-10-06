// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "outlier_feature_data_classifier",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(name: "StarCore", path: "../StarCore"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
      .executableTarget(
        name: "outlier_feature_data_classifier",
        dependencies: [
          .product(name: "ArgumentParser", package: "swift-argument-parser"),
          .product(name: "StarCore", package: "StarCore"),
        ],
        linkerSettings: [
          // use old, slower linker for now to avoid so many linker warnings
          .unsafeFlags([ "-Xlinker", "-ld_classic" ]),
          /*              .linkedLibrary("StarDecisionTrees")*/
        ]),
    ]
)
