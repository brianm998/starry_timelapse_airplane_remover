// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

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
// GPUCapability/GPUOps (StarCppBridge, pure Swift) call into Metal directly —
// see GPU_IMPLEMENTATION_GUIDE.md. Only StarCppBridge needs this; the C++
// StarCpp target stays Metal-free and calls a registered function pointer
// instead (GPUOps_C.h), matching the "no ObjC++ in StarCpp" rule.
let bridgeSwiftLinkerSettings: [LinkerSetting] = [
    .linkedFramework("Metal"),
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

// No Metal on Linux; GPUCapability.isAvailable() returns false and StarCppBridge
// links nothing extra here.
let bridgeSwiftLinkerSettings: [LinkerSetting] = []

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
// No Metal on Windows; GPUCapability.isAvailable() returns false and
// StarCppBridge links nothing extra here.
let bridgeSwiftLinkerSettings: [LinkerSetting] = []

// Eigen3 headers — unzip to C:\eigen3 (see windows_start.txt step 5f).
// MSVC headers are found automatically; no need to list them explicitly.
//
// _ALLOW_COMPILER_AND_STL_VERSION_MISMATCH: MSVC 14.44 STL headers contain a
// static_assert requiring Clang 19+, but the Swift toolchain bundles an older
// Clang. This is the documented Microsoft escape hatch to bypass that check.
// (Setting CL=/D... globally instead breaks CMake's compiler probe for OpenCV.)
// NOTE: we use .unsafeFlags rather than .define here — empirically .define
// did not propagate to the C++ compile on Windows in CI, while unsafeFlags
// in the same block (the -I flag below) does reliably reach the compiler.
let starcppCXXSettings: [CXXSetting] = [
    .unsafeFlags([
        "-IC:/eigen3",
        "-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH",
    ]),
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
let bridgeSwiftLinkerSettings: [LinkerSetting] = []
let starcppCXXSettings: [CXXSetting] = []
let bridgeCXXSettings: [CXXSetting] = [
    .unsafeFlags(["-I../opencv/include"]),
]
#endif

// ---------------------------------------------------------------------------
// wgpu-native (the Vulkan / Direct3D 12 / Metal GPU backend, WGPUBackend.cpp)
//
// Provided before the build by `wgpu/fetch.sh`, the way opencv/ is, and git-ignored. When the
// platform's directory is there the backend is compiled and linked; when it is not, WGPUBackend.cpp
// builds as stubs that say "not available" and nothing else changes. It also stays dormant at run
// time unless STAR_WGPU is set (see WGPUOps_C.h).
//
// The manifest does not re-run when that directory appears: after fetching, touch this file (or
// `swift package reset`) so the next build notices.
// ---------------------------------------------------------------------------
#if os(macOS)
  #if arch(arm64)
let wgpuPlatform = "macos-aarch64"
  #else
let wgpuPlatform = "macos-x86_64"
  #endif
#elseif os(Linux)
  #if arch(arm64)
let wgpuPlatform = "linux-aarch64"
  #else
let wgpuPlatform = "linux-x86_64"
  #endif
#elseif os(Windows)
let wgpuPlatform = "windows-x86_64-msvc"
#else
let wgpuPlatform = ""
#endif

let wgpuRoot = URL(fileURLWithPath: Context.packageDirectory)
    .deletingLastPathComponent()
    .appendingPathComponent("wgpu/\(wgpuPlatform)").path
let haveWGPU = !wgpuPlatform.isEmpty
    && FileManager.default.fileExists(atPath: wgpuRoot + "/include/webgpu/webgpu.h")

// unsafeFlags, not .define: a plain .define did not reach the C++ compile on Windows (see the Eigen
// note above), while unsafeFlags in the same block does.
let wgpuCXXSettings: [CXXSetting] = haveWGPU
    ? [.unsafeFlags(["-DSTAR_HAVE_WGPU", "-I\(wgpuRoot)/include"])]
    : []

#if os(macOS)
let wgpuLinkerSettings: [LinkerSetting] = haveWGPU ? [
    .unsafeFlags(["-Xlinker", "\(wgpuRoot)/lib/libwgpu_native.a"]),
    .linkedFramework("Metal"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("Foundation"),
    .linkedFramework("IOKit"),
    .linkedLibrary("c++"),
] : []
#elseif os(Linux)
let wgpuLinkerSettings: [LinkerSetting] = haveWGPU ? [
    .unsafeFlags(["-Xlinker", "\(wgpuRoot)/lib/libwgpu_native.a"]),
    .linkedLibrary("dl"),
    .linkedLibrary("m"),
    .linkedLibrary("pthread"),
] : []
#elseif os(Windows)
let wgpuLinkerSettings: [LinkerSetting] = haveWGPU ? [
    .unsafeFlags(["-Xlinker", "\(wgpuRoot)/lib/wgpu_native.lib"]),
    .linkedLibrary("d3d12"), .linkedLibrary("dxgi"), .linkedLibrary("d3dcompiler"),
    .linkedLibrary("userenv"), .linkedLibrary("ws2_32"), .linkedLibrary("ntdll"),
    .linkedLibrary("bcrypt"), .linkedLibrary("advapi32"), .linkedLibrary("ole32"),
    .linkedLibrary("oleaut32"), .linkedLibrary("user32"), .linkedLibrary("gdi32"),
    .linkedLibrary("opengl32"), .linkedLibrary("propsys"), .linkedLibrary("runtimeobject"),
] : []
#else
let wgpuLinkerSettings: [LinkerSetting] = []
#endif

// How hot the C++ is compiled in a release build.  SwiftPM's own release configuration (the cli, the
// daemon) is -O2, but the macOS gui is built by Xcode, whose Release configuration compiles a package's
// C++ at -Os — optimise for size — and the loops that spend a run's CPU (the median merge's fallback
// kernel, the cloud-aware stage, the SIFT and AKAZE tails, the Random Walker, the DP horizon, KHT) are
// all in this package.  Measured on the median kernel, same source, same machine: 80 ns per
// pixel-channel at -O2 against 135 at -Os, the sort inside it 3.4x slower.  Stating the level here makes
// the two builds the same; clang takes the last -O it is given, and the check that this one is the last
// is the compile line Xcode logs for ImageAligner.cpp.  Release only: a debug build stays -O0.
let optimizationCXXSettings: [CXXSetting] = [
    .unsafeFlags(["-O2"], .when(configuration: .release)),
]

// Each piece is declared and typed on its own: one big array literal with a closure in it was more than
// the manifest's type-checker would take.
let libraryTargets: [Target] = [
    .target(name: "kht",             // C++ Hough Transform implementation
            path: "Sources/kht",
            cxxSettings: starcppCXXSettings + optimizationCXXSettings,
            linkerSettings: platformLinkerSettings + wgpuLinkerSettings
    ),
    .target(name: "StarCpp",         // C++ OpenCV / StarCpp bridge (all .cpp)
            dependencies: ["kht"],
            path: "Sources/StarCpp",
            publicHeadersPath: "include",
            cxxSettings: bridgeCXXSettings + wgpuCXXSettings + optimizationCXXSettings
    ),
    .target(name: "StarCppBridge",   // Swift wrapper
            dependencies: [
                "StarCpp",
                .product(name: "logging", package: "logging"),
            ],
            path: "Sources/StarCppBridge",
            linkerSettings: bridgeSwiftLinkerSettings
    ),
]

// The geometry in StarCppBridge (Line, StandardLine, DoubleCoord) is pure Swift
// and every horizon/blob decision downstream is built on it, so it is worth
// pinning independently of the OpenCV code it sits next to.  platformLinkerSettings
// is repeated here because the test bundle links OpenCV itself: `kht` carries
// those settings for the library link, but a test target gets its own link step.
let bridgeTests: Target = .testTarget(
    name: "StarCppBridgeTests",
    dependencies: ["StarCppBridge"],
    path: "Tests/StarCppBridgeTests",
    linkerSettings: platformLinkerSettings + wgpuLinkerSettings
)

// The wgpu backend's tests, in a target of their own. StarCppBridgeTests is written for the Mac it is
// developed on (Darwin, mach_task_self_, Metal) and does not compile on Linux, on Windows, or with the
// newer toolchain a CI macOS runner has, and SwiftPM compiles a whole test target even for `--filter`.
// wgpu.yml sets STAR_ONLY_WGPU_TESTS to build just this one; a plain `swift test` is unchanged.
#if os(macOS)
let wgpuTestLinkerSettings: [LinkerSetting] = platformLinkerSettings + wgpuLinkerSettings
#else
// On Linux and Windows `kht` already carries OpenCV's whole-archive link (and wgpu's), and a test bundle
// inherits it through its dependencies; repeating it here made every OpenCV member defined twice
// ("multiple definition of 'zlibVersion'" from ld.gold). macOS links archives lazily, so the repeat is harmless there.
let wgpuTestLinkerSettings: [LinkerSetting] = []
#endif

let wgpuTests: Target = .testTarget(
    name: "StarCppWGPUTests",
    dependencies: ["StarCppBridge"],
    path: "Tests/StarCppWGPUTests",
    linkerSettings: wgpuTestLinkerSettings
)

let onlyWGPUTests = ProcessInfo.processInfo.environment["STAR_ONLY_WGPU_TESTS"] != nil
let testTargets: [Target] = onlyWGPUTests ? [wgpuTests] : [bridgeTests, wgpuTests]

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
    targets: libraryTargets + testTargets,
    cxxLanguageStandard: .cxx2b
)
