// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Platform-specific paths for pre-compiled StarDecisionTrees.
// All three platforms consume the artifacts produced by
// StarDecisionTrees/release.sh, which writes into lib/release/<platform>/
// and include/release/<platform>/. There is no separate debug build script.
#if os(macOS)
let dtIncludeDebug   = "../StarDecisionTrees/include/release/macos"
let dtLibDebug       = "../StarDecisionTrees/lib/release/macos"
let dtLibDebugFile   = "../StarDecisionTrees/lib/release/macos/libStarDecisionTrees.a"
#elseif os(Linux)
let dtIncludeDebug   = "../StarDecisionTrees/include/release/linux"
let dtLibDebug       = "../StarDecisionTrees/lib/release/linux"
let dtLibDebugFile   = "../StarDecisionTrees/lib/release/linux/libStarDecisionTrees.a"
#elseif os(Windows)
// SPM on Windows produces TargetName.lib (no "lib" prefix, .lib not .a).
let dtIncludeDebug   = "../StarDecisionTrees/include/release/windows"
let dtLibDebug       = "../StarDecisionTrees/lib/release/windows"
let dtLibDebugFile   = "../StarDecisionTrees/lib/release/windows/StarDecisionTrees.lib"
#else
let dtIncludeDebug   = "../StarDecisionTrees/include/debug"
let dtLibDebug       = "../StarDecisionTrees/lib/debug"
let dtLibDebugFile   = "../StarDecisionTrees/lib/debug/libStarDecisionTrees.a"
#endif

let package = Package(
    name: "star",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
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
            swiftSettings: [
              .unsafeFlags([
                             // import StarDecisionTrees swift module
                             "-l", "StarDecisionTrees",
                             "-I", dtIncludeDebug
                           ]),
            ],
            linkerSettings: [
              .unsafeFlags([
                             // link in pre compiled .a file for the decision trees
                             "-L\(dtLibDebug)",
                             "-Xlinker", dtLibDebugFile
                           ]),
              .linkedLibrary("StarDecisionTrees")
            ]),
        .testTarget(
            name: "starTests",
            dependencies: ["star"]),
    ]
)
