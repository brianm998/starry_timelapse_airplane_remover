// swift-tools-version: 6.0
import PackageDescription

// Deliberately does not depend on StarCore: the kernel is pure data so it links into the cli tests
// and the gui UI-test bundle without pulling in OpenCV.
let package = Package(
    name: "StarGherkin",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StarGherkinKernel", targets: ["StarGherkinKernel"]),
        .executable(name: "star-gherkin-gen", targets: ["star-gherkin-gen"]),
    ],
    targets: [
        .target(name: "StarGherkinKernel"),
        .executableTarget(name: "star-gherkin-gen"),
    ]
)
