// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Platform-specific paths for pre-compiled StarDecisionTrees.
// All three platforms consume the artifacts produced by
// StarDecisionTrees/release.sh, which writes into lib/release/<platform>/
// and include/release/<platform>/. There is no separate debug build script.
//
// Absolute, not "../StarDecisionTrees/...": a relative path in unsafeFlags is
// resolved against whatever working directory the build system gives the tool,
// and the build systems disagree. The native one resolves it from this
// directory, but swiftbuild (the `swift build` default as of Swift 6.4) runs
// the Swift driver with -working-directory set to the common ancestor of the
// local packages — the repo root — so "../StarDecisionTrees" points beside the
// checkout and `import StarDecisionTrees` fails with "unable to resolve module
// dependency". Its link step does still run from here, so the relative library
// paths kept working, but they are absolute too rather than relying on that.
// (StarCpp/Package.swift gets around the same thing for its OpenCV headers
// with .headerSearchPath, which has no equivalent for a Swift module path.)
let dtRoot = "\(Context.packageDirectory)/../StarDecisionTrees"
#if os(macOS)
let dtIncludeDebug   = "\(dtRoot)/include/release/macos"
let dtLibDebug       = "\(dtRoot)/lib/release/macos"
let dtLibDebugFile   = "\(dtRoot)/lib/release/macos/libStarDecisionTrees.a"
#elseif os(Linux)
let dtIncludeDebug   = "\(dtRoot)/include/release/linux"
let dtLibDebug       = "\(dtRoot)/lib/release/linux"
let dtLibDebugFile   = "\(dtRoot)/lib/release/linux/libStarDecisionTrees.a"
#elseif os(Windows)
// SPM on Windows produces TargetName.lib (no "lib" prefix, .lib not .a).
let dtIncludeDebug   = "\(dtRoot)/include/release/windows"
let dtLibDebug       = "\(dtRoot)/lib/release/windows"
let dtLibDebugFile   = "\(dtRoot)/lib/release/windows/StarDecisionTrees.lib"
#else
let dtIncludeDebug   = "\(dtRoot)/include/debug"
let dtLibDebug       = "\(dtRoot)/lib/debug"
let dtLibDebugFile   = "\(dtRoot)/lib/debug/libStarDecisionTrees.a"
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
            dependencies: ["star"],
            // `@testable import star` pulls in star's own `import StarDecisionTrees`,
            // and the test bundle links star's objects, so the tests need the same
            // include path and the same pre-compiled archive the executable does.
            // Joined `-I<path>`, not `-I <path>`: SwiftPM appends `-plugin-path` for the
            // testing library right after a test target's unsafeFlags, and a trailing
            // `-I` swallows it, leaving the plugin dir as a stray input file.
            swiftSettings: [
              .unsafeFlags([
                             "-I\(dtIncludeDebug)"
                           ]),
            ],
            linkerSettings: [
              .unsafeFlags([
                             "-L\(dtLibDebug)",
                             "-Xlinker", dtLibDebugFile
                           ]),
              .linkedLibrary("StarDecisionTrees")
            ]),
    ]
)
