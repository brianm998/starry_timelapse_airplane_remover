// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// this package exposes the kernel hough transform to swift, which needs the c++ opencv2 lib

// ---------------------------------------------------------------------------
// Platform-specific settings
//
// NOTE: kht_bridge contains only .cpp files, so all include-path settings
// must be in cxxSettings, not cSettings.  cSettings only applies to .c files
// and would be silently ignored for C++ compilation.
// ---------------------------------------------------------------------------

#if os(macOS)
let opencvLibPath = "../opencv/lib/macos"
let opencvLib    = "../opencv/lib/macos/libopencv2.a"
let platformLinkerSettings: [LinkerSetting] = [
    .linkedFramework("Accelerate"),
    .linkedFramework("OpenCL"),
    .unsafeFlags(["-L\(opencvLibPath)", "-Xlinker", opencvLib]),
    .linkedLibrary("opencv2"),
]
// Eigen is installed via Homebrew on macOS (arm: /opt/homebrew, intel: /usr/local)
let khtCXXSettings: [CXXSetting] = [
    .unsafeFlags([
        "-I/opt/homebrew/include/eigen3",   // Apple Silicon
        "-I/usr/local/include/eigen3",      // Intel
    ]),
]
// headerSearchPath (not unsafeFlags) is required for macOS/Xcode — Xcode resolves
// headerSearchPath correctly but resolves unsafeFlags -I relative to a different
// working directory.  "../../opencv/include" is relative to Sources/ in SPM,
// which puts it at the repo root's opencv/include/.
let bridgeCXXSettings: [CXXSetting] = khtCXXSettings + [
    .headerSearchPath("../../opencv/include"),
]

#elseif os(Linux)
let opencvLibPath = "../opencv/lib/linux"
let opencvLib    = "../opencv/lib/linux/libopencv2.a"
let platformLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(opencvLibPath)", "-Xlinker", opencvLib,
        // Swift's bundled Clang doesn't search GCC's lib dirs, so ld.gold
        // can't resolve -lstdc++ without these explicit search paths.
        // List multiple GCC versions; ld silently ignores non-existent ones.
        "-L/usr/lib/gcc/\(gccArchDir)/11",
        "-L/usr/lib/gcc/\(gccArchDir)/12",
        "-L/usr/lib/gcc/\(gccArchDir)/13",
        "-L/usr/lib/\(gccArchDir)",
    ]),
    .linkedLibrary("opencv2"),
    .linkedLibrary("stdc++"),
    .linkedLibrary("z"),
    .linkedLibrary("pthread"),
]

// Swift's bundled Clang on Linux doesn't automatically find the system GCC
// C++ standard library headers (libstdc++).  We list several GCC versions so
// this works on Ubuntu 22.04 (GCC 11/12) and Ubuntu 24.04 (GCC 13) without
// extra -Xcc flags.  Clang silently ignores any -I path that doesn't exist.
//
// The arch-specific subdir:  x86_64 → x86_64-linux-gnu
//                            arm64  → aarch64-linux-gnu
#if arch(x86_64)
let gccArchDir = "x86_64-linux-gnu"
#elseif arch(arm64)
let gccArchDir = "aarch64-linux-gnu"
#else
let gccArchDir = "linux-gnu"   // fallback; harmless if it doesn't exist
#endif

// kht (Hough Transform core) needs eigen + GCC C++ stdlib headers.
// kht_bridge additionally needs the OpenCV headers.
let khtCXXSettings: [CXXSetting] = [
    .unsafeFlags([
        "-I/usr/include/eigen3",
        // GCC C++ stdlib headers — list several versions for portability:
        "-I/usr/include/c++/11",
        "-I/usr/include/c++/12",
        "-I/usr/include/c++/13",
        "-I/usr/include/\(gccArchDir)/c++/11",
        "-I/usr/include/\(gccArchDir)/c++/12",
        "-I/usr/include/\(gccArchDir)/c++/13",
    ]),
]
let bridgeCXXSettings: [CXXSetting] = khtCXXSettings + [
    .unsafeFlags(["-I../opencv/include"]),  // same relative base as linker's ../opencv/lib/linux
]

#else
let opencvLibPath = "../opencv/lib"
let opencvLib    = "../opencv/lib/libopencv2.a"
let platformLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(opencvLibPath)", "-Xlinker", opencvLib]),
    .linkedLibrary("opencv2"),
]
let khtCXXSettings: [CXXSetting] = []
let bridgeCXXSettings: [CXXSetting] = [
    .unsafeFlags(["-I../opencv/include"]),
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
    targets: [
        .target(name: "kht",             // C++ Hough Transform implementation
                cxxSettings: khtCXXSettings,
                linkerSettings: platformLinkerSettings
        ),
        .target(name: "kht_bridge",      // C++ OpenCV / KHT bridge (all .cpp)
                dependencies: ["kht"],
                publicHeadersPath: "include",
                cxxSettings: bridgeCXXSettings
        ),
        .target(name: "KHTSwift",        // Swift wrapper
                dependencies: [
                    "kht_bridge",
                    .product(name: "logging", package: "logging"),
                ]
        ),
    ],
    cxxLanguageStandard: .cxx2b
)
