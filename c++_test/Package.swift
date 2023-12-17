// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "cpp_test",
    dependencies: [
        .package(name: "kht", path: "../kht")
    ],
    targets: [
        .executableTarget(
          name: "cpp_test",
          dependencies: [
            .product(name: "kht", package: "kht"),
          ],
          swiftSettings: [.interoperabilityMode(.Cxx)]
        )
    ]
)
