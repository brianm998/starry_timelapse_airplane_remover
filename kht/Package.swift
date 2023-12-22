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
    dependencies: [
      .package(name: "OpenCV", path: "../../opencv-spm")
// XXX this ^^^ works, but this VVV doesn't, the opencv-spm name isn't the package name :(
//      .package(url: "https://github.com/yeatse/opencv-spm.git", from: "4.8.1"),
    ],
    targets: [
      .target(name: "kht", dependencies: ["OpenCV"]),    // C++
      .target(name: "kht_bridge", dependencies: ["kht"]),     // Objective C
      .target(name: "KHTSwift", dependencies: ["kht_bridge"]) // Swift
    ],
    cxxLanguageStandard: .cxx2b
)
