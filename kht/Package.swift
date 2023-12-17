// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "KHTSwift",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "KHTSwift",
            targets: ["KHTSwift"])
    ],
    targets: [
      .target(name: "kht"),                                   // C++
      .target(name: "kht_bridge", dependencies: ["kht"]),     // Objective C
      .target(name: "KHTSwift", dependencies: ["kht_bridge"]) // Swift
    ],
    cxxLanguageStandard: .cxx2b
)
