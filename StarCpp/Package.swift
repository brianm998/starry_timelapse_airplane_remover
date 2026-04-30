// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// this package (StarCpp) exposes the kernel hough transform to swift, which needs the c++ opencv2 lib

// ---------------------------------------------------------------------------
// Platform-specific settings
//
// NOTE: StarCpp contains only .cpp files, so all include-path settings
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
let starcppCXXSettings: [CXXSetting] = [
    .unsafeFlags([
        "-I/opt/homebrew/include/eigen3",   // Apple Silicon
        "-I/usr/local/include/eigen3",      // Intel
    ]),
]
// headerSearchPath (not unsafeFlags) is required for macOS/Xcode — Xcode resolves
// headerSearchPath correctly but resolves unsafeFlags -I relative to a different
// working directory.  "../../opencv/include" is relative to Sources/ in SPM,
// which puts it at the repo root's opencv/include/.
//
// For `swift build` CLI, unsafeFlags -I resolves relative to the package root
// (StarCpp/), so "../opencv/include" reaches the repo root's opencv/include/.
// Both settings are present so that CLI and Xcode builds both find the headers.
let bridgeCXXSettings: [CXXSetting] = starcppCXXSettings + [
    .headerSearchPath("../../opencv/include"),
    .unsafeFlags(["-I../opencv/include"]),
]

#elseif os(Linux)
let opencvLibPath = "../opencv/lib/linux"
let opencvLib    = "../opencv/lib/linux/libopencv2.a"

// Swift's bundled Clang on Linux doesn't automatically find the system GCC
// C++ standard library headers (libstdc++).  We list several GCC versions so
// this works on Ubuntu 22.04 (GCC 11/12) and Ubuntu 24.04 (GCC 13) without
// extra -Xcc flags.  Clang silently ignores any -I path that doesn't exist.
//
// The arch-specific subdir:  x86_64 → x86_64-linux-gnu
//                            arm64  → aarch64-linux-gnu
//
// IMPORTANT: gccArchDir must be defined BEFORE platformLinkerSettings below,
// because Package.swift top-level lets execute sequentially.
#if arch(x86_64)
let gccArchDir = "x86_64-linux-gnu"
#elseif arch(arm64)
let gccArchDir = "aarch64-linux-gnu"
#else
let gccArchDir = "linux-gnu"   // fallback; harmless if it doesn't exist
#endif

let platformLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(opencvLibPath)",
        // ld.gold only extracts archive members that satisfy already-unresolved
        // symbols at the point the archive is scanned.  With a monolithic OpenCV
        // .a the scan order means cv::fastMalloc, cv::parallel_for_, JPEG codecs,
        // etc. are never extracted.  --whole-archive forces all members in, then
        // --no-whole-archive restores normal behaviour for subsequent libraries.
        "-Xlinker", "--whole-archive",
        "-Xlinker", opencvLib,
        "-Xlinker", "--no-whole-archive",
        // Swift's bundled Clang doesn't search GCC's lib dirs automatically.
        // List multiple GCC versions; ld silently ignores non-existent paths.
        "-L/usr/lib/gcc/\(gccArchDir)/11",
        "-L/usr/lib/gcc/\(gccArchDir)/12",
        "-L/usr/lib/gcc/\(gccArchDir)/13",
        "-L/usr/lib/\(gccArchDir)",
        // ld.gold verifies .so dependency chains at link time and rejects
        // libswiftObservation.so's reference to swift::threading::fatal
        // (defined in libswiftCore.so, resolved at runtime via rpath).
        // --allow-shlib-undefined suppresses this false-positive.
        "-Xlinker", "--allow-shlib-undefined",
    ]),
    .linkedLibrary("stdc++"),
    .linkedLibrary("z"),
    .linkedLibrary("pthread"),
]

// starcpp (Hough Transform core) needs eigen + GCC C++ stdlib headers.
// StarCpp additionally needs the OpenCV headers.
let starcppCXXSettings: [CXXSetting] = [
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
let bridgeCXXSettings: [CXXSetting] = starcppCXXSettings + [
    .unsafeFlags(["-I../opencv/include"]),  // same relative base as linker's ../opencv/lib/linux
]

#elseif os(Windows)
let opencvLibPath = "../opencv/lib/windows"
let opencvLib    = "../opencv/lib/windows/opencv2.lib"

// lld-link (COFF mode) uses /WHOLEARCHIVE:path to force all archive members
// to be included, equivalent to GNU ld's --whole-archive.
// The flag and path are a single linker token, passed via one -Xlinker argument.
//
// NOTE: if the build fails with "file not found" on opencv2.lib, lld-link may
// need a Windows-style path (backslashes).  In that case replace the opencvLib
// string above with the absolute Windows path, e.g.:
//   "C:\\Users\\brian\\git\\star_release\\opencv\\lib\\windows\\opencv2.lib"
let platformLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(opencvLibPath)",
        "-Xlinker", "/WHOLEARCHIVE:\(opencvLib)",
    ]),
]

// Eigen3 headers — unzip to C:\eigen3 (see windows_start.txt step 5f).
// MSVC headers are found automatically; no need to list them explicitly.
let starcppCXXSettings: [CXXSetting] = [
    .unsafeFlags(["-IC:/eigen3"]),
]
let bridgeCXXSettings: [CXXSetting] = starcppCXXSettings + [
    .unsafeFlags(["-I../opencv/include"]),
]

#else
let opencvLibPath = "../opencv/lib"
let opencvLib    = "../opencv/lib/libopencv2.a"
let platformLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(opencvLibPath)", "-Xlinker", opencvLib]),
    .linkedLibrary("opencv2"),
]
let starcppCXXSettings: [CXXSetting] = []
let bridgeCXXSettings: [CXXSetting] = [
    .unsafeFlags(["-I../opencv/include"]),
]
#endif

let package = Package(
    name: "StarCpp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "StarCppBridge",
            targets: ["StarCppBridge"])
    ],
    dependencies: [
        .package(name: "logging", path: "../logging"),
    ],
    targets: [
        .target(name: "kht",             // C++ Hough Transform implementation
                path: "Sources/kht",
                cxxSettings: starcppCXXSettings,
                linkerSettings: platformLinkerSettings
        ),
        .target(name: "StarCpp",         // C++ OpenCV / StarCpp bridge (all .cpp)
                dependencies: ["kht"],
                path: "Sources/StarCpp",
                publicHeadersPath: "include",
                cxxSettings: bridgeCXXSettings
        ),
        .target(name: "StarCppBridge",   // Swift wrapper
                dependencies: [
                    "StarCpp",
                    .product(name: "logging", package: "logging"),
                ],
                path: "Sources/StarCppBridge"
        ),
    ],
    cxxLanguageStandard: .cxx2b
)
