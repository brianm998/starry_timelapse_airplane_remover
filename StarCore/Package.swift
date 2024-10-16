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
      .package(url: "https://github.com/JohnSundell/ShellOut.git", from: "2.3.0"),
      .package(url: "https://github.com/groue/Semaphore.git", from: "0.0.8"),
      .package(name: "KHTSwift", path: "../kht"),
      .package(name: "logging", path: "../logging"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "StarCore",
            dependencies: [
              .product(name: "ShellOut", package: "ShellOut"),
              .product(name: "Semaphore", package: "Semaphore"),
              .product(name: "KHTSwift", package: "KHTSwift"),
              .product(name: "logging", package: "logging"),
            ]
        ),
        .testTarget(
            name: "StarCoreTests",
            dependencies: ["StarCore"]),
    ]
)

