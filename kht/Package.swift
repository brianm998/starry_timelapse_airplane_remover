// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// this package exposes the kernel hough transform to swift, which needs the c++ opencv2 lib

// Platform-specific OpenCV library path and linker settings
#if os(macOS)
let opencvLibPath = "../opencv/lib/macos"
let opencvLib = "../opencv/lib/macos/libopencv2.a"
let platformLinkerSettings: [LinkerSetting] = [
    .linkedFramework("Accelerate"),
    .linkedFramework("OpenCL"),
    .unsafeFlags(["-L\(opencvLibPath)", "-Xlinker", opencvLib]),
    .linkedLibrary("opencv2")
]
let eigenCSettings: [CSetting] = [
    .unsafeFlags([
                   "-I/opt/homebrew/include/eigen3", // arm
                   "-I/usr/local/include/eigen3"     // intel
                 ]),
    .headerSearchPath("../../opencv/include"),
]
#elseif os(Linux)
let opencvLibPath = "../opencv/lib/linux"
let opencvLib = "../opencv/lib/linux/libopencv2.a"
let platformLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(opencvLibPath)", "-Xlinker", opencvLib]),
    .linkedLibrary("opencv2"),
    // Linux equivalents of Accelerate/OpenCL — link what's available
    .linkedLibrary("z"),
    .linkedLibrary("pthread"),
]
let eigenCSettings: [CSetting] = [
    .unsafeFlags(["-I/usr/include/eigen3"]),
    .headerSearchPath("../../opencv/include"),
]
#else
let opencvLibPath = "../opencv/lib"
let opencvLib = "../opencv/lib/libopencv2.a"
let platformLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(opencvLibPath)", "-Xlinker", opencvLib]),
    .linkedLibrary("opencv2")
]
let eigenCSettings: [CSetting] = [
    .headerSearchPath("../../opencv/include"),
]
#endif

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
      .package(name: "logging", path: "../logging"),
    ],
    targets: [                  // C++
      .target(name: "kht",
              linkerSettings: platformLinkerSettings
      ),
      .target(name: "kht_bridge", // C++ (was Objective-C)
              dependencies: ["kht"],
              publicHeadersPath: "include",
              cSettings: eigenCSettings
      ),
      .target(name: "KHTSwift", // Swift
              dependencies: [
                "kht_bridge",
                .product(name: "logging", package: "logging")
              ]
      )
    ],
    cxxLanguageStandard: .cxx2b
)
