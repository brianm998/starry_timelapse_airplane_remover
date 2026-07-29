// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StarCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "StarCore",
            targets: ["StarCore"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
      .package(url: "https://github.com/groue/Semaphore.git", from: "0.0.8"),
      .package(name: "StarCpp", path: "../StarCpp"),
      .package(name: "logging", path: "../logging"),
    ],
    targets: [
        .target(
            name: "StarCoreSQLite",
            path: "Sources/StarCoreSQLite"
        ),
        .target(
            name: "StarCoreC",
            path: "Sources/StarCoreC",
            linkerSettings: [
              // star_process_footprint's _WIN32 branch calls GetProcessMemoryInfo, which
              // lives in psapi. Windows CI has not reached the link step yet — it was
              // still failing to compile — so this is ahead of the error rather than
              // after it.
              .linkedLibrary("psapi", .when(platforms: [.windows])),
            ]
        ),
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "StarCore",
            dependencies: [
              "StarCoreC",
              // StarCoreSQLite is a vendored SQLite (newer than the one in
              // Apple's SDK). On macOS we use the system SQLite3 framework
              // module via `#if canImport(SQLite3)` in HomographyDatabase.swift
              // — and depending on StarCoreSQLite there is actively harmful:
              // SPM would put its include/ on the header search path, and
              // Clang's <sqlite3.h> resolution while building the system
              // SQLite3 module would find our newer sqlite3.h first, then
              // fail with a struct sqlite3_module ODR mismatch ('xIntegrity'
              // present in ours, absent in Apple's). So gate this dependency
              // on non-Apple platforms only.
              .target(name: "StarCoreSQLite",
                      condition: .when(platforms: [.linux, .windows])),
              .product(name: "Semaphore", package: "Semaphore"),
              .product(name: "StarCppBridge", package: "StarCpp"),
              .product(name: "logging", package: "logging"),
            ],
            resources: [
              // Pre-compiled CoreML tile classifier.
              // Re-generate with:
              //   xcrun coremlc compile tile_classifier.mlpackage \
              //       StarCore/Sources/StarCore/Resources/
              .copy("Resources/tile_classifier.mlmodelc"),
            ]
        ),
        .testTarget(
            name: "StarCoreTests",
            dependencies: ["StarCore"]),
    ]
)
