// swift-tools-version: 6.0
import PackageDescription

#if os(macOS)
let dtInclude = "../StarDecisionTrees/include/release/macos"
let dtLib     = "../StarDecisionTrees/lib/release/macos"
let dtLibFile = "../StarDecisionTrees/lib/release/macos/libStarDecisionTrees.a"
#elseif os(Linux)
let dtInclude = "../StarDecisionTrees/include/release/linux"
let dtLib     = "../StarDecisionTrees/lib/release/linux"
let dtLibFile = "../StarDecisionTrees/lib/release/linux/libStarDecisionTrees.a"
#elseif os(Windows)
let dtInclude = "../StarDecisionTrees/include/release/windows"
let dtLib     = "../StarDecisionTrees/lib/release/windows"
let dtLibFile = "../StarDecisionTrees/lib/release/windows/StarDecisionTrees.lib"
#else
let dtInclude = "../StarDecisionTrees/include/release/macos"
let dtLib     = "../StarDecisionTrees/lib/release/macos"
let dtLibFile = "../StarDecisionTrees/lib/release/macos/libStarDecisionTrees.a"
#endif

let package = Package(
    name: "StarDaemon",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(name: "StarCore", path: "../StarCore"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "StarDaemonMessages",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/StarDaemonMessages"
        ),
        .executableTarget(
            name: "stard",
            dependencies: [
                "StarDaemonMessages",
                .product(name: "StarCore",     package: "StarCore"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/stard",
            swiftSettings: [
                .unsafeFlags(["-l", "StarDecisionTrees", "-I", dtInclude]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(dtLib)", "-Xlinker", dtLibFile]),
                .linkedLibrary("StarDecisionTrees"),
            ]
        ),
        .testTarget(
            name: "StarDaemonTests",
            dependencies: [
                "StarDaemonMessages",
                .product(name: "StarCore", package: "StarCore"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Tests/StarDaemonTests",
            linkerSettings: [
                .unsafeFlags(["-L\(dtLib)", "-Xlinker", dtLibFile]),
                .linkedLibrary("StarDecisionTrees"),
            ]
        ),
    ]
)
