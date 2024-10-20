// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "cpp_test",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
//        .package(name: "KHTSwift", path: "../kht")
        .package(name: "StarCore", path: "../StarCore")
    ],
    targets: [
        .executableTarget(
          name: "cpp_test",
          dependencies: [
            .product(name: "StarCore", package: "StarCore"),
          ],
          linkerSettings: [ .unsafeFlags([ "-Xlinker", "-ld_classic" ]) ]
        )
    ]
)
