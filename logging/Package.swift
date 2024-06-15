// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "logging",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "logging",
            targets: ["logging"]),
    ],
    dependencies: [
      .package(url: "https://github.com/groue/Semaphore.git", from: "0.0.8"),
    ],
    targets: [
        .target(
            name: "logging",
            dependencies: [
              .product(name: "Semaphore", package: "Semaphore"),
            ]
        )
    ]
)
