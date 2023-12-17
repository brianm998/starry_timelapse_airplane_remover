// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "cpp_test",
    products: [
      .library(name: "kht", targets: ["kht"])
    ],
    targets: [
        .target(name: "kht"),
        .executableTarget(
          name: "cpp_test",
          dependencies: [
            .target(name: "kht"),
          ],
          swiftSettings: [.interoperabilityMode(.Cxx)]
        )
    ],
    cxxLanguageStandard: .cxx11
)
