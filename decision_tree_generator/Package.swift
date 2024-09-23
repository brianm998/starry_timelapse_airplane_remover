// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "decision_tree_generator",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
        .package(name: "StarCore", path: "../StarCore"),
        .package(name: "StarDecisionTrees", path: "../StarDecisionTrees"),
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
            swiftSettings: [
              .unsafeFlags([
                             // import libStarDecisionTrees.a for references at compile time
                             "-l", "StarDecisionTrees",
                             "-I", "../StarDecisionTrees/include/debug"
                           ]),
            ],
            linkerSettings: [
              .unsafeFlags([
                             // use old, slower linker for now to avoid so many linker warnings
                             "-Xlinker", "-ld_classic",
                             
                             // link in pre compiled .a file for the decision trees 
                             "-L../StarDecisionTrees/lib/debug",
                             "-Xlinker", "../StarDecisionTrees/lib/debug/libStarDecisionTrees.a"
                           ]),
              .linkedLibrary("StarDecisionTrees")
            ]),
        .testTarget(
            name: "decision_tree_generatorTests",
            dependencies: ["decision_tree_generator"]),
    ]
)
