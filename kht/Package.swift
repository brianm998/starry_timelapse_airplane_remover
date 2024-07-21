// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// this package exposes the kernel hough transform to swift, which needs the c++ opencv2 lib
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
              linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Accelerate"),
                .linkedFramework("OpenCL"),
                .unsafeFlags([
                               // use old, slower linker for now to avoid so many linker warnings
                               //"-Xlinker", "-ld_classic",
                               
                               // link in pre compiled .a file for opencv2 
                               "-L../opencv/lib/",
                               "-Xlinker", "../opencv/lib/libopencv2.a"
                             ]
                ),
                .linkedLibrary("opencv2")
              ]

      ),      
      .target(name: "kht_bridge", // Objective C
              dependencies: ["kht"],
              cxxSettings: [ .unsafeFlags([ "-I", "../opencv/include" ])]
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
