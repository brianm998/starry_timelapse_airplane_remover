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
                // Depending on stard itself is what lets the tests exercise the real
                // Mapping/Dispatcher/SessionManager rather than hand-copied shims of them.
                // The shims in EnumParityTests predate this and could drift from
                // Mapping.swift without anything noticing.  cli/Package.swift already
                // takes this shape for the `star` executable target.
                "stard",
                "StarDaemonMessages",
                .product(name: "StarCore", package: "StarCore"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Tests/StarDaemonTests",
            // `@testable import stard` pulls in stard's own `import StarDecisionTrees`, so
            // the test bundle needs the same include path and archive the executable does.
            // Joined `-I<path>`, not `-I <path>`: SwiftPM appends `-plugin-path` for the
            // testing library right after a test target's unsafeFlags, and a trailing `-I`
            // would swallow it.
            swiftSettings: [
                .unsafeFlags(["-I\(dtInclude)"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(dtLib)", "-Xlinker", dtLibFile]),
                .linkedLibrary("StarDecisionTrees"),
            ]
        ),
    ]
)
